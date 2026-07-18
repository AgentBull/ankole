import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  statSync,
  writeFileSync
} from 'node:fs'
import { tmpdir } from 'node:os'
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
import type { CodexJobWorkspaceMount } from './job-project'
import { WORKSPACE_MODEL_ROOT } from '../workspace-paths'

export const CODEX_JOB_SKILLS_SANDBOX_ROOT = '/ankole/job-skills'

export type MaterializedCodexJobSkill = {
  name: string
  sourcePath: string
  skillFileOverridePath?: string
}

export type MaterializedCodexJobRuntimeFiles = {
  root: string
  skillsPlaceholderRoot: string
  skills: MaterializedCodexJobSkill[]
  expectedSkillNames: string[]
  cleanup(): void
}

export async function materializeCodexJobRuntimeFiles(input: {
  turn: ActorTurnRef
  enabledSkills: RuntimeSkillSummary[]
  skillRoots?: SkillFileRoots
  rpc: RPCRequester
}): Promise<MaterializedCodexJobRuntimeFiles> {
  const root = mkdtempSync(join(tmpdir(), 'ankole-codex-job-runtime-'))

  try {
    const skillsPlaceholderRoot = join(root, 'skills')
    mkdirSync(skillsPlaceholderRoot, { recursive: true })
    const skills = await materializeSkills(input, root, skillsPlaceholderRoot)

    return {
      root,
      skillsPlaceholderRoot,
      skills,
      expectedSkillNames: skills.map(skill => skill.name),
      cleanup: () => rmSync(root, { recursive: true, force: true })
    }
  } catch (error) {
    rmSync(root, { recursive: true, force: true })
    throw error
  }
}

export function renderCodexJobAgents(input: {
  guidanceWorkspaceRoot: string
  workspaceMounts: CodexJobWorkspaceMount[]
  soul: string
  mission: string
  brainSnapshot?: BrainSnapshot
  background?: string
  notes?: string
  timezone?: string | null
  now?: Date
}): { content: string } {
  const localAgents = input.workspaceMounts.map(mount => ({
    mount,
    content: readLocalAgents(input.guidanceWorkspaceRoot, mount)
  }))

  return {
    content: renderTaskAgents({
      localGuidance: localAgents
        .filter(item => item.content)
        .map(item => `## Mounted workspace guidance: ${item.mount.id}\n\n${item.content}`)
        .join('\n\n'),
      workspaceMounts: input.workspaceMounts,
      soul: input.soul,
      mission: input.mission,
      brainSnapshot: input.brainSnapshot,
      background: input.background,
      notes: input.notes,
      timezone: input.timezone,
      now: input.now ?? new Date()
    })
  }
}

async function materializeSkills(
  input: Parameters<typeof materializeCodexJobRuntimeFiles>[0],
  root: string,
  skillsPlaceholderRoot: string
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
      const sourcePath = realpathSync(
        resolveSkillFilesystemRoot(skill, { skillRoots: input.skillRoots!, turn: input.turn })
      )
      if (!statSync(sourcePath).isDirectory()) throw new Error(`skill source is not a directory: ${skill.skillName}`)
      const sourceSkillPath = join(sourcePath, 'SKILL.md')
      if (!existsSync(sourceSkillPath)) throw new Error(`enabled skill is missing SKILL.md: ${skill.skillName}`)

      mkdirSync(join(skillsPlaceholderRoot, skill.skillName), { recursive: true })
      const overlay = await resolveSkillOverlayText(skill.skillName, {
        turn: input.turn,
        rpc: input.rpc
      })
      if (!overlay) return { name: skill.skillName, sourcePath }

      const skillFileOverridePath = join(root, 'skill-overrides', skill.skillName, 'SKILL.md')
      mkdirSync(join(root, 'skill-overrides', skill.skillName), { recursive: true })
      writeFileSync(skillFileOverridePath, composeNativeSkillFile(readFileSync(sourceSkillPath, 'utf8'), overlay), {
        mode: 0o600
      })
      return { name: skill.skillName, sourcePath, skillFileOverridePath }
    })
  )
}

function readLocalAgents(guidanceWorkspaceRoot: string, mount: CodexJobWorkspaceMount): string {
  const realGuidanceRoot = realpathSync(guidanceWorkspaceRoot)
  const realUserFilesRoot = existsSync(join(guidanceWorkspaceRoot, 'user-files'))
    ? realpathSync(join(guidanceWorkspaceRoot, 'user-files'))
    : undefined
  for (const name of ['AGENTS.override.md', 'AGENTS.md'] as const) {
    const path = join(mount.sourcePath, name)
    if (!existsSync(path)) continue
    const realPath = realpathSync(path)
    if (!insideRoot(realGuidanceRoot, realPath) && (!realUserFilesRoot || !insideRoot(realUserFilesRoot, realPath))) {
      throw new Error(`local ${name} escapes the owner workspace guidance roots`)
    }
    if (!statSync(realPath).isFile()) continue
    return readFileSync(realPath, 'utf8').trim()
  }
  return ''
}

function renderTaskAgents(input: {
  localGuidance: string
  workspaceMounts: CodexJobWorkspaceMount[]
  soul: string
  mission: string
  brainSnapshot?: BrainSnapshot
  background?: string
  notes?: string
  timezone?: string | null
  now: Date
}): string {
  const workspaceLines = input.workspaceMounts.length
    ? input.workspaceMounts.map(mount => `- ${mount.id}: ${mount.modelPath} (${mount.access})`).join('\n')
    : '- No target workspace is mounted.'
  const executionContext = [
    `Current time: ${input.now.toISOString()}${input.timezone ? ` (${input.timezone})` : ''}.`,
    `Job project root (the process cwd): ${WORKSPACE_MODEL_ROOT}.`,
    `Mounted workspaces:\n${workspaceLines}`,
    'Your final message is the Job result for the caller. State outcomes, evidence, relevant paths, and remaining risks.',
    'The caller owns user-visible replies, attachments, scheduling, and durable Skill writes. Projected Brain tools operate only inside the server-validated caller conversation scope.',
    'If genuinely required information is missing, the lead agent must call request_parent_input; child agents must report the question to the lead. Do not call request_user_input, which is unavailable in this background execution.',
    'Complete foreground work before ending the turn; do not leave required shell jobs running in the background.'
  ].join('\n')

  return [
    input.localGuidance,
    '# Ankole Background Agent Job Context',
    section('SOUL', input.soul),
    section('MISSION', input.mission),
    section('Durable Context', formatAgentDurableContext(input.brainSnapshot)),
    section('Background', input.background),
    section('Notes', input.notes),
    section('Execution Context', executionContext)
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

function insideRoot(root: string, path: string): boolean {
  return path === root || path.startsWith(`${root}/`)
}

function compareCodePoints(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0
}
