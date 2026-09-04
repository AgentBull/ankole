import { compareCodePointStrings } from '../../../common/ordering'
import { isRecord } from '@agentbull/active-support'
import { jsonObjectFromBytes } from '../../../fabric/envelope_proto'
import type { AgentPluginCatalogEntry, BackgroundAgentJobResponse, RuntimeSkillSummary } from '../../../lanes/rpc_lane'
import { skillAvailableInRuntime } from '../../../skills/effective-skill'
import type { ResolvedAgentWorkerEnv } from '../../execution/worker_env'

/**
 * The control plane freezes this projection when it creates the Job.
 * Resume can remove unavailable selections, but it must not add selections.
 * Operator variables use frozen names. Binding variables remain live.
 */
export type CodexJobRuntimeProjection = {
  version: 1
  modelRef: Record<string, unknown>
  runtimePolicy: Record<string, unknown>
  skillSelections: Array<{ id: string; name: string; agentPluginID?: string }>
  agentPluginSelections: Array<{ id: string; skills: string[] }>
  nativeMCPServers: []
  workerEnv: { names: string[]; plainValues: Record<string, string> }
  browser: { mode: 'persistent' }
}

export function decodeCodexJobRuntimeProjection(job: BackgroundAgentJobResponse): CodexJobRuntimeProjection {
  if (job.runtimeProjectionJson.length === 0) {
    throw new Error('Background agent Job is missing its runtime projection')
  }
  const value = jsonObjectFromBytes(job.runtimeProjectionJson, 'runtime_projection_json')
  if (!value || value.version !== 1 || !isRecord(value.model_ref)) {
    throw new Error('Background agent Job runtime projection has an unsupported version or model reference')
  }

  const workerEnv = objectValue(value.worker_env)
  const nativeMCPServers = arrayOfObjects(value.native_mcp_servers)
  if (nativeMCPServers.length > 0) {
    throw new Error('Background agent Job runtime projection contains unsupported native MCP servers')
  }
  const browser = objectValue(value.browser)
  if (browser.mode !== 'persistent') {
    throw new Error('Background agent Job runtime projection contains an unsupported browser mode')
  }
  return {
    version: 1,
    modelRef: value.model_ref,
    runtimePolicy: objectValue(value.runtime_policy),
    skillSelections: arrayOfObjects(value.skills).map((skill, index) => ({
      id: requiredString(skill.id, `runtime projection Skill ${index} id`),
      name: requiredString(skill.name, `runtime projection Skill ${index} name`),
      ...(optionalString(skill.agent_plugin_id) ? { agentPluginID: optionalString(skill.agent_plugin_id) } : {})
    })),
    agentPluginSelections: arrayOfObjects(value.agent_plugins).map((agentPlugin, index) => ({
      id: requiredString(agentPlugin.id, `runtime projection Agent Plugin ${index} id`),
      skills: stringArray(agentPlugin.skills, `runtime projection Agent Plugin ${index} Skills`)
    })),
    nativeMCPServers: [],
    workerEnv: {
      names: stringArray(workerEnv.names, 'runtime projection WorkerEnv names'),
      plainValues: stringMap(workerEnv.plain_values, 'runtime projection WorkerEnv plain values')
    },
    browser: { mode: 'persistent' }
  }
}

/**
 * Derives the Skills one Job run can load: the frozen selections that still
 * exist in the Agent's current catalog and run in a Background Job, in name
 * order. Standalone Skills come first; Agent Plugin Skills follow in the
 * projection's plugin order, sorted by catalog name inside each plugin.
 */
export function selectJobSkills(
  projection: CodexJobRuntimeProjection,
  catalog: { skills: RuntimeSkillSummary[]; agentPlugins: AgentPluginCatalogEntry[] }
): RuntimeSkillSummary[] {
  return [
    ...selectedStandaloneSkills(projection, catalog.skills),
    ...selectedAgentPluginSkills(projection, catalog)
  ].filter(skill => skillAvailableInRuntime(skill, 'background_job'))
}

function selectedStandaloneSkills(
  projection: CodexJobRuntimeProjection,
  current: RuntimeSkillSummary[]
): RuntimeSkillSummary[] {
  const selected = new Set(projection.skillSelections.filter(skill => !skill.agentPluginID).map(skill => skill.name))
  const byName = new Map<string, RuntimeSkillSummary>()
  for (const skill of current) {
    if (skill.agentPluginId || !selected.has(skill.skillName)) continue
    if (byName.has(skill.skillName)) {
      throw new Error(`Agent conversation Skill catalog has duplicate name: ${skill.skillName}`)
    }
    byName.set(skill.skillName, skill)
  }
  return [...byName.values()].sort((left, right) => compareCodePointStrings(left.skillName, right.skillName))
}

function selectedAgentPluginSkills(
  projection: CodexJobRuntimeProjection,
  catalog: { skills: RuntimeSkillSummary[]; agentPlugins: AgentPluginCatalogEntry[] }
): RuntimeSkillSummary[] {
  const currentPlugins = new Map(catalog.agentPlugins.map(agentPlugin => [agentPlugin.id, agentPlugin]))
  const currentMembers = new Map(
    catalog.skills
      .filter(skill => skill.agentPluginId)
      .map(skill => [memberKey(skill.agentPluginId, skill.skillName), skill])
  )
  const selectedMembers = new Set<string>()
  return projection.agentPluginSelections.flatMap(selection => {
    const currentPlugin = currentPlugins.get(selection.id)
    if (!currentPlugin) return []
    const selectedNames = new Set(selection.skills)
    return [...currentPlugin.skills]
      .filter(member => selectedNames.has(member.catalogName))
      .sort((left, right) => compareCodePointStrings(left.catalogName, right.catalogName))
      .map(member => {
        const key = memberKey(selection.id, member.catalogName)
        const skill = currentMembers.get(key)
        if (!skill) throw new Error(`Current Agent Plugin Skill is unavailable: ${selection.id}/${member.catalogName}`)
        if (selectedMembers.has(key)) {
          throw new Error(
            `Agent conversation Plugin Skill catalog has duplicate member: ${selection.id}/${member.catalogName}`
          )
        }
        selectedMembers.add(key)
        return skill
      })
  })
}

function memberKey(agentPluginID: string, catalogName: string): string {
  return `${agentPluginID}\0${catalogName}`
}

/**
 * Rebuilds the frozen Job environment from selected names and current values.
 * Current binding values win because the current signal route owns
 * credentials. Unselected operator values remain hidden.
 */
export function projectWorkerEnv(
  projection: CodexJobRuntimeProjection,
  current: ResolvedAgentWorkerEnv
): Record<string, string> {
  const selected: Record<string, string> = {}
  for (const name of projection.workerEnv.names) {
    const plainValue = projection.workerEnv.plainValues[name]
    const value = plainValue ?? current.operatorVars[name]
    if (value !== undefined) selected[name] = value
  }
  return { ...selected, ...current.bindingVars }
}

function arrayOfObjects(value: unknown): Record<string, unknown>[] {
  if (!Array.isArray(value)) throw new Error('Background agent Job runtime projection contains a non-array selection')
  return value.map((entry, index) => {
    if (!isRecord(entry)) throw new Error(`Background agent Job runtime projection entry ${index} is not an object`)
    return entry
  })
}

function objectValue(value: unknown): Record<string, unknown> {
  if (!isRecord(value)) throw new Error('Background agent Job runtime projection contains a non-object value')
  return value
}

function stringArray(value: unknown, label: string): string[] {
  if (!Array.isArray(value) || !value.every(item => typeof item === 'string' && item.length > 0)) {
    throw new Error(`${label} must be an array of non-empty strings`)
  }
  return [...new Set(value)].sort(compareCodePointStrings)
}

function stringMap(value: unknown, label: string): Record<string, string> {
  if (!isRecord(value)) throw new Error(`${label} must be an object`)
  const result: Record<string, string> = {}
  for (const [key, item] of Object.entries(value)) {
    if (!key || typeof item !== 'string') throw new Error(`${label} must contain only string values`)
    result[key] = item
  }
  return result
}

function requiredString(value: unknown, label: string): string {
  const result = optionalString(value)
  if (!result) throw new Error(`${label} must be a non-empty string`)
  return result
}

function optionalString(value: unknown): string | undefined {
  return typeof value === 'string' && value.length > 0 ? value : undefined
}
