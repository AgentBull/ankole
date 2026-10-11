import { readFile, realpath } from 'node:fs/promises'
import { normalize, resolve } from 'node:path'
import type { AgentToolResult } from '../core'
import type { JobTurnRef } from '../lanes/actor_lane'
import type { RPCRequester, RuntimeSkillSummary } from '../lanes/rpc_lane'
import {
  ankoleSkillRuntime,
  enabledSkillByName,
  resolveSkillFilesystemRoot,
  resolveSkillOverlayText,
  skillAvailableInRuntime,
  stripSkillFrontmatter,
  type AnkoleSkillRuntime,
  type SkillFileRoots
} from './effective-skill'

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
  turn: JobTurnRef
  enabledSkills?: RuntimeSkillSummary[]
  skillRoots?: SkillFileRoots
  rpc: RPCRequester
  onSkillLoaded?: (name: string) => void
}

/** Loads one effective Ankole Skill for a Background Job. */
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
      const declaredRuntime = ankoleSkillRuntime(skill)
      if (!skillAvailableInRuntime(skill, 'background_job')) {
        throw new Error(`skill is not available in the background_job runtime: ${params.name}`)
      }

      // This RPC also rechecks current effective enablement, so it must run
      // before every Skill file read, including references loaded mid-turn.
      const overlayContent = await resolveSkillOverlayText(params.name, opts)
      const absolute = await safeSkillPath(skillRoot, filePath)
      const content = await readFile(absolute, 'utf8')
      const rendered =
        filePath === 'SKILL.md'
          ? renderEffectiveSkill(params.name, skillRoot, declaredRuntime, content, overlayContent)
          : wrapSkillContent(params.name, skillLocation(params.name, filePath), skillRoot, declaredRuntime, content)
      opts.onSkillLoaded?.(params.name)
      return {
        content: [{ type: 'text', text: rendered }],
        details: { name: params.name, path: filePath }
      }
    }
  }
}

function renderEffectiveSkill(
  name: string,
  directory: string,
  runtime: AnkoleSkillRuntime,
  content: string,
  overlayContent: string
): string {
  const baseContent = stripSkillFrontmatter(content)
  const withOverlay = overlayContent
    ? `${baseContent}\n\n---\nAgent-specific additions:\n\n${overlayContent}`
    : baseContent
  return wrapSkillContent(name, skillLocation(name, 'SKILL.md'), directory, runtime, withOverlay)
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

function wrapSkillContent(
  name: string,
  location: string,
  directory: string,
  runtime: AnkoleSkillRuntime,
  content: string
): string {
  return [
    `<skill name="${escapeAttribute(name)}" location="${escapeAttribute(location)}" directory="${escapeAttribute(directory)}" runtime="${runtime}">`,
    '<external_content source="skill">',
    content,
    '</external_content>',
    '</skill>'
  ].join('\n')
}

function escapeAttribute(value: string): string {
  return value.replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
}
