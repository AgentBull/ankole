import { join, normalize } from 'node:path'
import type { JsonObject as JSONObject } from '@agentbull/active-support'
import { jsonObjectFromBytes } from '../fabric/envelope_proto'
import type { ActorTurnRef } from '../lanes/actor_lane'
import { rpcMethods, type RPCRequester, type RuntimeSkillSummary, type SkillOverlayResponse } from '../lanes/rpc_lane'

export interface SkillFileRoots {
  builtinSkillsRoot: string
  internalSkillsRoot?: string
  agentInstalledSkillsRoot: string
}

export type AnkoleSkillRuntime = 'any' | 'main' | 'background_job'
export type AnkoleSkillExecutionRuntime = Exclude<AnkoleSkillRuntime, 'any'>

export function enabledSkillByName(
  name: string,
  enabledSkills: RuntimeSkillSummary[] | undefined
): RuntimeSkillSummary {
  assertValidSkillName(name)
  if (!enabledSkills) throw new Error('skill tools require RuntimeFabric enabled skill metadata')

  const skill = enabledSkills.find(candidate => candidate.skillName === name)
  if (!skill) throw new Error(`skill is not enabled for this turn: ${name}`)
  return skill
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
  const relativePath = normalizeSkillRelativePath(skill.relativePath)
  const sourceKind = skill.sourceKind
  if (sourceKind === 'builtin') {
    const rootName = skill.skillRoot || undefined
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
  return (await resolveSkillOverlayTexts([name], input)).get(name)!
}

export async function resolveSkillOverlayTexts(
  names: string[],
  input: { turn: ActorTurnRef; rpc: RPCRequester }
): Promise<Map<string, string>> {
  const responses = await resolveSkillOverlayResponses(names, input)
  return new Map([...responses].map(([name, response]) => [name, overlayText(response)]))
}

async function resolveSkillOverlayResponses(
  names: string[],
  input: { turn: ActorTurnRef; rpc: RPCRequester }
): Promise<Map<string, SkillOverlayResponse>> {
  names.forEach(assertValidSkillName)
  if (new Set(names).size !== names.length) throw new Error('skill overlay names must be unique')
  if (names.length === 0) return new Map()

  const response = await input.rpc(rpcMethods.skillsOverlayResolve, { skillNames: names }, { turn: input.turn })
  const requested = new Set(names)
  const overlays = new Map<string, SkillOverlayResponse>()

  for (const overlay of response.overlays) {
    if (!requested.has(overlay.skillName)) throw new Error(`unexpected skill overlay response: ${overlay.skillName}`)
    if (overlays.has(overlay.skillName)) throw new Error(`duplicate skill overlay response: ${overlay.skillName}`)
    overlays.set(overlay.skillName, overlay)
  }

  for (const name of names) {
    if (!overlays.has(name)) throw new Error(`missing skill overlay response: ${name}`)
  }
  return overlays
}

function overlayText(response: SkillOverlayResponse): string {
  if (!response.hasOverlay) return ''
  return response.text.trim()
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
