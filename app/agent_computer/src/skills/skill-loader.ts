import { readFile, realpath } from 'node:fs/promises'
import { normalize, resolve } from 'node:path'
import type { AgentToolResult } from '../core'
import type { ActorTurnRef } from '../lanes/actor_lane'
import type { RPCRequester, RuntimeSkillSummary } from '../lanes/rpc_lane'
import {
  ankoleSkillRuntime,
  enabledSkillByName,
  resolveSkillFilesystemRoot,
  resolveSkillOverlayText,
  skillAvailableInRuntime,
  stripSkillFrontmatter,
  type AnkoleSkillExecutionRuntime,
  type SkillFileRoots
} from './effective-skill'

export const lazySkillSlugPrefix = 'lazyload-agent-skills/'

export type SkillLoadParams = {
  name: string
  filePath?: string
}

export type SkillLoadDetails = {
  name: string
  path: string
}

export type SkillLoader = {
  load(params: SkillLoadParams): Promise<AgentToolResult<SkillLoadDetails>>
  disable(names: string[]): void
}

export type CreateSkillLoaderOptions = {
  turn: ActorTurnRef
  enabledSkills?: RuntimeSkillSummary[]
  skillRoots?: SkillFileRoots
  rpc: RPCRequester
  runtime: AnkoleSkillExecutionRuntime
  onSkillLoaded?: (name: string) => void
}

/** Loads one effective Ankole Skill for either the main or Background Job runtime. */
export function createSkillLoader(opts: CreateSkillLoaderOptions): SkillLoader {
  const disabled = new Set<string>()

  return {
    disable(names) {
      for (const name of names) disabled.add(name)
    },
    async load(params) {
      const filePath = normalizeSkillFilePath(params.filePath ?? 'SKILL.md')
      if (disabled.has(params.name)) throw new Error(`skill is not enabled for this turn: ${params.name}`)
      const skill = enabledSkillByName(params.name, opts.enabledSkills)
      if (filePath === 'AGENT_APPEND.md') {
        throw new Error('skill overlays are DB-backed semantic data, not AGENT_APPEND.md files')
      }
      const skillRoot = skillFilesystemRoot(skill, opts.skillRoots)
      if (opts.runtime === 'main' && ankoleSkillRuntime(skill) === 'background_job') {
        if (filePath !== 'SKILL.md') {
          throw new Error(
            `background-job-only Skill resources are available only inside a background agent job; create one with create_background_job and name ${params.name} in its task`
          )
        }
        await resolveSkillOverlayText(params.name, opts)
        await safeSkillPath(skillRoot, 'SKILL.md')
        opts.onSkillLoaded?.(params.name)
        return {
          content: [{ type: 'text', text: backgroundJobSkillDispatchContent(params.name) }],
          details: { name: params.name, path: filePath }
        }
      }
      if (!skillAvailableInRuntime(skill, opts.runtime)) {
        throw new Error(`skill is not available in the ${opts.runtime} runtime: ${params.name}`)
      }

      // This RPC also rechecks current effective enablement, so it must run
      // before every Skill file read, including references loaded mid-turn.
      const overlayContent = await resolveSkillOverlayText(params.name, opts)
      const absolute = await safeSkillPath(skillRoot, filePath)
      const content = await readFile(absolute, 'utf8')
      const rendered =
        filePath === 'SKILL.md'
          ? renderEffectiveSkill(params.name, skillRoot, content, overlayContent)
          : wrapSkillContent(params.name, skillLocation(params.name, filePath), skillRoot, content)
      opts.onSkillLoaded?.(params.name)
      return {
        content: [{ type: 'text', text: rendered }],
        details: { name: params.name, path: filePath }
      }
    }
  }
}

export function lazySkillNameFromSlug(value: string): string | undefined {
  if (!value.startsWith(lazySkillSlugPrefix)) return undefined
  const name = value.slice(lazySkillSlugPrefix.length)
  return name && !name.includes('/') ? name : undefined
}

function renderEffectiveSkill(name: string, directory: string, content: string, overlayContent: string): string {
  const baseContent = stripSkillFrontmatter(content)
  const withOverlay = overlayContent
    ? `${baseContent}\n\n---\nAgent-specific additions:\n\n${overlayContent}`
    : baseContent
  return wrapSkillContent(name, skillLocation(name, 'SKILL.md'), directory, withOverlay)
}

function backgroundJobSkillDispatchContent(name: string): string {
  return [
    `The enabled ${name} Skill is a background-task capability.`,
    'Do not execute it inline and do not try to read its operational body or referenced resources from the main agent.',
    `Create a background agent job with create_background_job. Put the complete user request, constraints, paths, acceptance criteria, and an explicit instruction to use the ${name} Skill in the task.`,
    'The background agent job can load the complete enabled Skill and its resources with skill_view.'
  ].join('\n')
}

async function safeSkillPath(skillRoot: string, filePath: string): Promise<string> {
  const normalizedFilePath = normalizeSkillFilePath(filePath)
  const root = resolve(skillRoot)
  const resolved = resolve(root, normalizedFilePath)
  if (resolved !== root && !resolved.startsWith(`${root}/`)) {
    throw new Error('skill path escapes skill root')
  }

  const [realRoot, realResolved] = await Promise.all([realpath(root), realpath(resolved)])
  if (realResolved !== realRoot && !realResolved.startsWith(`${realRoot}/`)) {
    throw new Error('skill path escapes skill root through a symbolic link')
  }
  return realResolved
}

function skillFilesystemRoot(skill: RuntimeSkillSummary, skillRoots: SkillFileRoots | undefined): string {
  if (!skillRoots) throw new Error('skill_view requires worker skill source roots')
  return resolveSkillFilesystemRoot(skill, { skillRoots })
}

function normalizeSkillFilePath(filePath: string): string {
  const raw = filePath.replaceAll('\\', '/')
  if (raw.split('/').some(segment => segment === '..')) {
    throw new Error('invalid skill file path')
  }
  const normalized = normalize(raw).replaceAll('\\', '/')
  if (
    normalized.length === 0 ||
    normalized.startsWith('../') ||
    normalized === '..' ||
    normalized.startsWith('/') ||
    normalized.split('/').some(segment => segment === '' || segment === '.' || segment === '..')
  ) {
    throw new Error('invalid skill file path')
  }
  return normalized
}

function skillLocation(name: string, filePath: string): string {
  return `skill://enabled/${name}/${filePath}`
}

function wrapSkillContent(name: string, location: string, directory: string, content: string): string {
  return [
    `<skill name="${escapeAttribute(name)}" location="${escapeAttribute(location)}" directory="${escapeAttribute(directory)}">`,
    '<external_content source="skill">',
    content,
    '</external_content>',
    '</skill>'
  ].join('\n')
}

function escapeAttribute(value: string): string {
  return value.replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
}
