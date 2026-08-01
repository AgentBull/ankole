import { join, normalize } from 'node:path'
import { create } from '@bufbuild/protobuf'
import type { JsonObject as JSONObject } from '@pleisto/active-support'
import { jsonObjectFromBytes } from '../fabric/envelope_proto'
import type { ActorTurnRef } from '../lanes/actor_lane'
import { rpcMethods, RuntimeSkillSummarySchema, type RPCRequester, type RuntimeSkillSummary } from '../lanes/rpc_lane'

export interface SkillFileRoots {
  builtinSkillsRoot: string
  internalSkillsRoot?: string
  agentInstalledSkillsRoot: string
}

export type AnkoleSkillRuntime = 'any' | 'main' | 'background_job'
export type AnkoleSkillExecutionRuntime = Exclude<AnkoleSkillRuntime, 'any'>

export function enabledSkillByName(
  name: string,
  enabledSkills: Array<RuntimeSkillSummary | string> | undefined
): RuntimeSkillSummary {
  assertValidSkillName(name)
  if (!enabledSkills) throw new Error('skill tools require RuntimeFabric enabled skill metadata')

  const skill = enabledSkills.map(normalizeEnabledSkill).find(candidate => candidate?.skillName === name)
  if (!skill) throw new Error(`skill is not enabled for this turn: ${name}`)
  return skill
}

export function normalizeEnabledSkill(skill: RuntimeSkillSummary | string): RuntimeSkillSummary | undefined {
  if (typeof skill === 'string') {
    return isValidSkillName(skill)
      ? create(RuntimeSkillSummarySchema, { skillName: skill, sourceKind: 'builtin', relativePath: skill })
      : undefined
  }

  return typeof skill.skillName === 'string' && isValidSkillName(skill.skillName) ? skill : undefined
}

/** Parses the free-form skill metadata document; empty bytes mean no metadata. */
export function skillMetadata(skill: RuntimeSkillSummary): JSONObject {
  return jsonObjectFromBytes(skill.metadataJson, 'runtime_skill_summary.metadata_json') ?? {}
}

/** Returns the Ankole execution surface declared by one Skill. */
export function ankoleSkillRuntime(skill: RuntimeSkillSummary): AnkoleSkillRuntime {
  const value = skillMetadata(skill)['ankole-runtime']
  if (value === undefined || value === 'any') return 'any'
  if (value === 'main' || value === 'background_job') return value
  throw new Error(`invalid ankole-runtime for Skill ${skill.skillName}: ${String(value)}`)
}

/** Checks whether one Skill is available to the selected Ankole execution surface. */
export function skillAvailableInRuntime(skill: RuntimeSkillSummary, runtime: AnkoleSkillExecutionRuntime): boolean {
  const declared = ankoleSkillRuntime(skill)
  return declared === 'any' || declared === runtime
}

export function resolveSkillFilesystemRoot(skill: RuntimeSkillSummary, input: { skillRoots: SkillFileRoots }): string {
  const relativePath = normalizeSkillRelativePath(skill.relativePath || skill.skillName)
  const sourceKind = skill.sourceKind || 'builtin'
  if (sourceKind === 'builtin') {
    const rootName = skillRootName(skill)
    if (rootName === 'internal') {
      if (!input.skillRoots.internalSkillsRoot) {
        throw new Error(`internal skill root is not configured for builtin skill: ${skill.skillName}`)
      }
      return join(input.skillRoots.internalSkillsRoot, relativePath)
    }

    if (rootName && rootName !== 'library') {
      throw new Error(`unsupported builtin skill root ${rootName}: ${skill.skillName}`)
    }
    return join(input.skillRoots.builtinSkillsRoot, relativePath)
  }

  if (sourceKind === 'installed') {
    return join(input.skillRoots.agentInstalledSkillsRoot, relativePath)
  }

  throw new Error(`unsupported skill source_kind: ${sourceKind}`)
}

export async function resolveSkillOverlayText(
  name: string,
  input: { turn: ActorTurnRef; rpc: RPCRequester }
): Promise<string> {
  const response = await input.rpc(rpcMethods.skillsOverlayResolve, { skillName: name }, { turn: input.turn })
  const overlay = jsonObjectFromBytes(response.overlayJson, 'skill_overlay.overlay_json')
  const text = overlay?.text
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
  if (skill.skillRoot.length > 0) return skill.skillRoot
  const metadataRoot = skillMetadata(skill)['skill_root']
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
