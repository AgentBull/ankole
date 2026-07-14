import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  rmdirSync,
  statSync,
  writeFileSync
} from 'node:fs'
import { tmpdir } from 'node:os'
import { join, relative } from 'node:path'
import type { ActorTurnRef } from '../../lanes/actor_lane'
import type { RuntimeBrainSnapshot, RuntimeSkillSummary } from '../../lanes/rpc_lane'
import type { SkillOverlayRequester } from '../../core/turns/turn_options'
import { formatAgentDurableContext } from '../../prompts/durable_context'
import { insideWorkspace, WORKSPACE_MODEL_ROOT, WORKSPACE_USER_FILES_ROOT } from '../../core/workspace-paths'
import {
  assertValidSkillName,
  composeNativeSkillFile,
  normalizeEnabledSkill,
  resolveSkillFilesystemRoot,
  resolveSkillOverlayText,
  type SkillFileRoots
} from '../../skills/effective-skill'

export const SUBAGENT_SKILLS_SANDBOX_ROOT = '/ankole/subagent-skills'
export const SUBAGENT_AGENTS_SANDBOX_ROOT = `${WORKSPACE_MODEL_ROOT}/.ankole/subagent-runtime`

export type MaterializedSubagentSkill = {
  name: string
  sourcePath: string
  skillFileOverridePath?: string
}

export type MaterializedSubagentRuntimeFiles = {
  root: string
  agentsPath: string
  agentsSandboxPath: string
  localAgentsFilename?: 'AGENTS.override.md' | 'AGENTS.md'
  localAgentsSandboxPath?: string
  skillsPlaceholderRoot: string
  skills: MaterializedSubagentSkill[]
  expectedSkillNames: string[]
  cleanup(): void
}

export async function materializeSubagentRuntimeFiles(input: {
  workspaceRoot: string
  workdir: string
  workdirForModel: string
  durableArtifactsRootForModel: string
  soul: string
  mission: string
  brainSnapshot?: RuntimeBrainSnapshot
  background?: string
  notes?: string
  timezone?: string | null
  now?: Date
  turn: ActorTurnRef
  enabledSkills: RuntimeSkillSummary[]
  skillRoots?: SkillFileRoots
  requestSkillOverlay?: SkillOverlayRequester
}): Promise<MaterializedSubagentRuntimeFiles> {
  const root = mkdtempSync(join(tmpdir(), 'ankole-subagent-runtime-'))
  const workspaceRuntimeRoot = join(input.workspaceRoot, '.ankole')
  const workspaceAgentsRoot = join(workspaceRuntimeRoot, 'subagent-runtime')
  const mountID = crypto.randomUUID()
  const agentsMountpointPath = join(workspaceAgentsRoot, `${mountID}.md`)

  try {
    const mappings = workspaceMappings(input.workspaceRoot)
    const localAgents = readLocalAgents(mappings, input.workdir)
    const agentsPath = join(root, 'AGENTS.override.md')
    writeFileSync(
      agentsPath,
      renderTaskAgents({
        existingGuidance: localAgents.content,
        soul: input.soul,
        mission: input.mission,
        brainSnapshot: input.brainSnapshot,
        background: input.background,
        notes: input.notes,
        timezone: input.timezone,
        now: input.now ?? new Date(),
        workdirForModel: input.workdirForModel,
        durableArtifactsRootForModel: input.durableArtifactsRootForModel
      }),
      { mode: 0o600 }
    )
    mkdirSync(workspaceAgentsRoot, { recursive: true })
    writeFileSync(agentsMountpointPath, '', { mode: 0o600 })

    const skillsPlaceholderRoot = join(root, 'skills')
    mkdirSync(skillsPlaceholderRoot, { recursive: true })
    const skills = await materializeSkills(input, root, skillsPlaceholderRoot)

    return {
      root,
      agentsPath,
      agentsSandboxPath: `${SUBAGENT_AGENTS_SANDBOX_ROOT}/${mountID}.md`,
      ...(localAgents.filename ? { localAgentsFilename: localAgents.filename } : {}),
      ...(localAgents.sandboxPath ? { localAgentsSandboxPath: localAgents.sandboxPath } : {}),
      skillsPlaceholderRoot,
      skills,
      expectedSkillNames: skills.map(skill => skill.name),
      cleanup: () =>
        cleanupRuntimeFiles({
          root,
          agentsMountpointPath,
          workspaceAgentsRoot,
          workspaceRuntimeRoot
        })
    }
  } catch (error) {
    cleanupRuntimeFiles({
      root,
      agentsMountpointPath,
      workspaceAgentsRoot,
      workspaceRuntimeRoot
    })
    throw error
  }
}

async function materializeSkills(
  input: Parameters<typeof materializeSubagentRuntimeFiles>[0],
  root: string,
  skillsPlaceholderRoot: string
): Promise<MaterializedSubagentSkill[]> {
  const enabledSkills = input.enabledSkills
    .map(skill => {
      const normalized = normalizeEnabledSkill(skill)
      if (!normalized) throw new Error(`enabled skill has invalid name: ${skill.skill_name}`)
      return normalized
    })
    .sort((left, right) => left.skill_name.localeCompare(right.skill_name))

  if (new Set(enabledSkills.map(skill => skill.skill_name)).size !== enabledSkills.length) {
    throw new Error('enabled skill names must be unique')
  }
  if (enabledSkills.length > 0 && !input.skillRoots) {
    throw new Error('Codex enabled skills require worker skill source roots')
  }

  return await Promise.all(
    enabledSkills.map(async skill => {
      assertValidSkillName(skill.skill_name)
      const sourcePath = realpathSync(
        resolveSkillFilesystemRoot(skill, { skillRoots: input.skillRoots!, turn: input.turn })
      )
      if (!statSync(sourcePath).isDirectory()) throw new Error(`skill source is not a directory: ${skill.skill_name}`)
      const sourceSkillPath = join(sourcePath, 'SKILL.md')
      if (!existsSync(sourceSkillPath)) throw new Error(`enabled skill is missing SKILL.md: ${skill.skill_name}`)

      mkdirSync(join(skillsPlaceholderRoot, skill.skill_name), { recursive: true })
      const overlay = await resolveSkillOverlayText(skill.skill_name, {
        turn: input.turn,
        requestSkillOverlay: input.requestSkillOverlay
      })
      if (!overlay) return { name: skill.skill_name, sourcePath }

      const skillFileOverridePath = join(root, 'skill-overrides', skill.skill_name, 'SKILL.md')
      mkdirSync(join(root, 'skill-overrides', skill.skill_name), { recursive: true })
      writeFileSync(skillFileOverridePath, composeNativeSkillFile(readFileSync(sourceSkillPath, 'utf8'), overlay), {
        mode: 0o600
      })
      return { name: skill.skill_name, sourcePath, skillFileOverridePath }
    })
  )
}

function readLocalAgents(
  allowedRoots: WorkspaceMapping[],
  workdir: string
): { content: string; filename?: 'AGENTS.override.md' | 'AGENTS.md'; sandboxPath?: string } {
  for (const name of ['AGENTS.override.md', 'AGENTS.md'] as const) {
    const path = join(workdir, name)
    if (!existsSync(path)) continue
    const realPath = realpathSync(path)
    const sandboxPath = sandboxPathForRealPath(allowedRoots, realPath, `local ${name} escapes the delegated workspace`)
    if (!statSync(realPath).isFile()) continue
    const content = readFileSync(realPath, 'utf8').trim()
    return {
      content,
      filename: name,
      sandboxPath
    }
  }
  return { content: '' }
}

type WorkspaceMapping = { host: string; sandbox: string }

function workspaceMappings(workspaceRoot: string): WorkspaceMapping[] {
  const mappings = [{ host: realpathSync(workspaceRoot), sandbox: WORKSPACE_MODEL_ROOT }]
  const userFilesPath = join(workspaceRoot, 'user-files')
  if (existsSync(userFilesPath)) {
    mappings.push({ host: realpathSync(userFilesPath), sandbox: WORKSPACE_USER_FILES_ROOT })
  }
  return mappings
}

function sandboxPathForRealPath(mappings: WorkspaceMapping[], realPath: string, errorMessage: string): string {
  const root = mappings.find(candidate => insideWorkspace(candidate.host, realPath))
  if (!root) throw new Error(errorMessage)
  return join(root.sandbox, relative(root.host, realPath))
}

function cleanupRuntimeFiles(input: {
  root: string
  agentsMountpointPath: string
  workspaceAgentsRoot: string
  workspaceRuntimeRoot: string
}): void {
  rmSync(input.root, { recursive: true, force: true })
  rmSync(input.agentsMountpointPath, { force: true })
  removeEmptyDirectory(input.workspaceAgentsRoot)
  removeEmptyDirectory(input.workspaceRuntimeRoot)
}

function removeEmptyDirectory(path: string): void {
  try {
    rmdirSync(path)
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT' && (error as NodeJS.ErrnoException).code !== 'ENOTEMPTY') {
      throw error
    }
  }
}

function renderTaskAgents(input: {
  existingGuidance: string
  soul: string
  mission: string
  brainSnapshot?: RuntimeBrainSnapshot
  background?: string
  notes?: string
  timezone?: string | null
  now: Date
  workdirForModel: string
  durableArtifactsRootForModel: string
}): string {
  const executionContext = [
    `Current time: ${input.now.toISOString()}${input.timezone ? ` (${input.timezone})` : ''}.`,
    `Working directory: ${input.workdirForModel}.`,
    `Durable artifacts belong under ${input.durableArtifactsRootForModel}.`,
    'Your final message is a delegation report for the parent agent. Include outcomes, evidence, artifact paths, and remaining risks.',
    'Use Codex requestUserInput when a decision is required. The parent agent owns user-visible replies, attachments, scheduling, and durable skill writes. Projected Brain tools may read and write durable memory within the server-validated parent conversation scope.',
    'Complete foreground work before ending the turn; do not leave required shell jobs running in the background.'
  ].join('\n')

  return [
    input.existingGuidance,
    '# Ankole Subagent Context',
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
