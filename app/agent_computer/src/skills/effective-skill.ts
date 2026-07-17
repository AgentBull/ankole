import { join, normalize } from 'node:path'
import type { ActorTurnRef } from '../lanes/actor_lane'
import { rpcMethods, type RPCRequester, type RuntimeSkillSummary } from '../lanes/rpc_lane'

export interface SkillFileRoots {
  builtinSkillsRoot: string
  internalSkillsRoot?: string
  agentInstalledSkillsRoot: string
}

export function enabledSkillByName(
  name: string,
  enabledSkills: Array<RuntimeSkillSummary | string> | undefined
): RuntimeSkillSummary {
  assertValidSkillName(name)
  if (!enabledSkills) throw new Error('skill tools require RuntimeFabric enabled skill metadata')

  const skill = enabledSkills.map(normalizeEnabledSkill).find(candidate => candidate?.skill_name === name)
  if (!skill) throw new Error(`skill is not enabled for this turn: ${name}`)
  return skill
}

export function normalizeEnabledSkill(skill: RuntimeSkillSummary | string): RuntimeSkillSummary | undefined {
  if (typeof skill === 'string') {
    return isValidSkillName(skill) ? { skill_name: skill, source_kind: 'builtin', relative_path: skill } : undefined
  }

  return typeof skill.skill_name === 'string' && isValidSkillName(skill.skill_name) ? skill : undefined
}

export function resolveSkillFilesystemRoot(
  skill: RuntimeSkillSummary,
  input: { skillRoots: SkillFileRoots; turn?: ActorTurnRef }
): string {
  const relativePath = normalizeSkillRelativePath(skill.relative_path || skill.skill_name)
  const sourceKind = skill.source_kind || 'builtin'
  if (sourceKind === 'builtin') {
    const rootName = skillRootName(skill)
    if (rootName === 'internal') {
      if (!input.skillRoots.internalSkillsRoot) {
        throw new Error(`internal skill root is not configured for builtin skill: ${skill.skill_name}`)
      }
      return join(input.skillRoots.internalSkillsRoot, relativePath)
    }

    if (rootName && rootName !== 'library') {
      throw new Error(`unsupported builtin skill root ${rootName}: ${skill.skill_name}`)
    }
    return join(input.skillRoots.builtinSkillsRoot, relativePath)
  }

  if (sourceKind === 'installed') {
    if (!input.turn) throw new Error('installed skill requires an actor turn')
    return join(input.skillRoots.agentInstalledSkillsRoot, input.turn.actor.agent_uid, relativePath)
  }

  throw new Error(`unsupported skill source_kind: ${sourceKind}`)
}

export async function resolveSkillOverlayText(
  name: string,
  input: { turn: ActorTurnRef; rpc: RPCRequester }
): Promise<string> {
  const response = await input.rpc(rpcMethods.skillsOverlayResolve, {
    turn: input.turn,
    skill_name: name
  })
  const text = response.overlay_json?.text
  return typeof text === 'string' ? text.trim() : ''
}

export function composeNativeSkillFile(baseContent: string, overlayContent: string): string {
  const base = baseContent.trimEnd()
  const overlay = overlayContent.trim()
  return overlay ? `${base}\n\n---\nAgent-specific additions:\n\n${overlay}\n` : `${base}\n`
}

export function stripSkillFrontmatter(content: string): string {
  if (!content.startsWith('---')) return content.trim()
  const match = /^---\r?\n[\s\S]*?\r?\n---\r?\n?([\s\S]*)$/.exec(content)
  return (match?.[1] ?? content).trim()
}

export function assertValidSkillName(name: string): void {
  if (!isValidSkillName(name)) throw new Error('invalid skill name')
}

export function isValidSkillName(name: string): boolean {
  return /^[a-z][a-z0-9_-]{0,63}$/.test(name)
}

function skillRootName(skill: RuntimeSkillSummary): string | undefined {
  if (typeof skill.skill_root === 'string' && skill.skill_root.length > 0) return skill.skill_root
  const metadataRoot = skill.metadata?.['skill_root']
  return typeof metadataRoot === 'string' && metadataRoot.length > 0 ? metadataRoot : undefined
}

function normalizeSkillRelativePath(relativePath: string): string {
  const raw = relativePath.replaceAll('\\', '/').replace(/^\/+/, '').replace(/\/+/g, '/')
  if (raw.split('/').some(segment => segment === '.' || segment === '..')) {
    throw new Error(`invalid skill relative_path: ${relativePath}`)
  }
  const normalized = normalize(raw).replaceAll('\\', '/')
  if (
    normalized.length === 0 ||
    normalized === '.' ||
    normalized === '..' ||
    normalized.startsWith('../') ||
    normalized.split('/').some(segment => segment === '' || segment === '.' || segment === '..')
  ) {
    throw new Error(`invalid skill relative_path: ${relativePath}`)
  }
  return normalized
}
