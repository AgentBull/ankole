import type { TurnStart } from '../../lanes/actor_lane'
import {
  memoryRPCRequester,
  rpcMethods,
  type AIGatewayAPIKeyResponse,
  type AgentPluginCatalogEntry,
  type BackgroundAgentJobResponse,
  type RuntimeSkillSummary
} from '../../lanes/rpc_lane'
import { prepareActorWorkspace } from '../../worker/workspace'
import { materializeCodexConfig } from '../../tools/codex/config'
import { stringValue } from '../../tools/codex/protocol'
import { resolveCodexRuntimeConfig } from '../../tools/codex/runtime-config'
import { codexAppServerSandboxSpec } from '../../tools/codex/sandbox'
import { createMemoryTools } from '../../tools/memory/memory-tools'
import {
  browserSandboxRuntime,
  withoutBrowserMaterialSourceEnv,
  type MaterializedBrowserRuntime
} from '../../browser-runtime'
import { httpClientFromAIGatewayAPIKey } from '../ai_gateway_transport'
import { resolveAgentConversationContext } from '../turns/turn_context'
import { createTurnWebTools, resolveRenderedFetchRuntimeConfig } from '../turns/rendered_fetch_runtime_config'
import { resolveWorkerEnv } from '../turns/worker_env'
import type { CodexJobOptions } from '../turns/turn_options'
import { join } from 'node:path'
import { assertAgentPluginProjectResumeState, prepareAgentPlugins } from './agent-plugin-materializer'
import { codexJobProjectLocation, prepareCodexJobProject, type CodexJobWorkspaceMountInput } from './job-project'
import { resolveCodexJobMCPServers } from './mcp-config'
import { parentInputToolSpec } from './parent-input'
import { materializeCodexJobProjectConfig } from './project-config'
import { buildCodexJobProjection } from './projection'
import { materializeCodexJobRuntimeFiles, renderCodexJobAgents } from './runtime-files'

export type CodexJobSetupInput = {
  turnStart: TurnStart
  opts: CodexJobOptions
  jobID: string
  job: BackgroundAgentJobResponse
}

export async function prepareCodexJobExecution(input: CodexJobSetupInput) {
  const { turnStart, opts, jobID, job } = input
  const parentWorkspaceRoot = prepareActorWorkspace(
    {
      workspaceSessionsRoot: opts.workspaceSessionsRoot,
      userFilesRoot: opts.userFilesRoot
    },
    { agent_uid: job.agentUid, session_id: job.ownerSessionId }
  )
  const agentContext = await resolveAgentConversationContext(turnStart, opts)
  const availableSkills = agentContext.skills ?? []
  const enabledSkills = selectCurrentStandaloneSkills(job.skillNames, availableSkills)
  const agentPluginCatalogResponse = await opts.rpc(rpcMethods.agentPluginList, {}, { turn: turnStart.turn })
  const selectedAgentPlugins = selectCurrentAgentPlugins(job.agentPluginIds, agentPluginCatalogResponse.agentPlugins)
  const agentPluginSkills = selectCurrentAgentPluginSkills(selectedAgentPlugins, availableSkills)
  const skillRoots = {
    builtinSkillsRoot: opts.builtinSkillsRoot,
    agentInstalledSkillsRoot: opts.agentInstalledSkillsRoot,
    ...(opts.internalSkillsRoot ? { internalSkillsRoot: opts.internalSkillsRoot } : {})
  }
  const projectLocation = codexJobProjectLocation(opts.userFilesRoot, jobID)
  if (job.runtimeThreadId) assertAgentPluginProjectResumeState(projectLocation.hostPath)

  // Validate every caller-owned mount before Agent Plugin recovery may rebuild
  // the private project that sits beside those mounts.
  const preflightProject = prepareCodexJobProject({
    jobProjectRoot: projectLocation.hostPath,
    ownerModelPath: projectLocation.ownerModelPath,
    ownerWorkspaceRoot: parentWorkspaceRoot,
    allowedSourceRoots: [opts.userFilesRoot],
    workspaceMounts: jobWorkspaceMounts(job)
  })
  const initializeProject = !job.runtimeThreadId
  const agentsContent = initializeProject
    ? renderCodexJobAgents({
        guidanceWorkspaceRoot: parentWorkspaceRoot,
        workspaceMounts: preflightProject.workspaceMounts,
        soul: agentContext.soul ?? '',
        mission: agentContext.mission ?? '',
        brainSnapshot: agentContext.brainSnapshot,
        background: job.background,
        notes: job.notes,
        timezone: agentContext.conversation?.timezone
      }).content
    : undefined
  const preparedAgentPlugins = prepareAgentPlugins({
    projectRoot: projectLocation.hostPath,
    agentPlugins: selectedAgentPlugins,
    initializeProject,
    ...(agentsContent ? { agentsContent } : {})
  })
  const jobProject = prepareCodexJobProject({
    jobProjectRoot: projectLocation.hostPath,
    ownerModelPath: projectLocation.ownerModelPath,
    ownerWorkspaceRoot: parentWorkspaceRoot,
    allowedSourceRoots: [opts.userFilesRoot],
    workspaceMounts: jobWorkspaceMounts(job)
  })
  const mcpServers = await resolveCodexJobMCPServers({
    enabledSkills: [...enabledSkills, ...agentPluginSkills],
    skillRoots,
    turn: turnStart.turn
  })
  const runtimeConfig = await resolveCodexRuntimeConfig({
    turn: turnStart.turn,
    job,
    requesters: opts
  })
  const materialized = materializeCodexConfig({
    sharedFsRoot: opts.sharedFsRoot,
    jobID,
    runtime: runtimeConfig,
    enablePlugins: selectedAgentPlugins.length > 0
  })
  const projectConfig = materializeCodexJobProjectConfig({
    projectRoot: jobProject.root,
    execution: {
      ...(job.model ? { model: job.model } : {}),
      ...(job.reasoningEffort ? { reasoningEffort: job.reasoningEffort } : {})
    },
    mcpServers,
    pluginsEnabled: selectedAgentPlugins.length > 0
  })
  const projectionAPIKey =
    runtimeConfig.mode === 'aigateway'
      ? runtimeConfig.aiGatewayKey
      : await requestProjectionAIGatewayKey(turnStart, opts)
  const projectionAIGateway = httpClientFromAIGatewayAPIKey(projectionAPIKey, options =>
    requestProjectionAIGatewayKey(turnStart, opts, options)
  )
  const renderedFetchRuntimeConfig = await resolveRenderedFetchRuntimeConfig(turnStart, opts.rpc)
  const workerEnv = await resolveWorkerEnv(turnStart, opts.rpc)
  const codexWorkerEnv = withoutBrowserMaterialSourceEnv(workerEnv)
  const baseWebTools = await createTurnWebTools({
    aiGateway: projectionAIGateway,
    renderedFetchRuntimeConfig,
    workerEnv,
    browserRuntime: opts.browserRuntime,
    abortSignal: opts.abortSignal
  })
  const projectedTools = [
    ...baseWebTools,
    // Brain attributes job-issued memory operations to the job because the
    // turn fence session is the job session; no extra scope payload is needed.
    ...createMemoryTools({
      turnStart,
      requestMemoryRPC: memoryRPCRequester(opts.rpc, turnStart.turn)
    })
  ]
  const projection = buildCodexJobProjection({ tools: projectedTools })
  projection.dynamicTools.push(parentInputToolSpec())
  const runtimeFiles = await materializeCodexJobRuntimeFiles({
    turn: turnStart.turn,
    enabledSkills,
    skillRoots,
    rpc: opts.rpc
  })
  let browserRuntimeMaterial: MaterializedBrowserRuntime | undefined
  let sandbox: ReturnType<typeof codexAppServerSandboxSpec>
  try {
    browserRuntimeMaterial = await opts.browserRuntime?.materializePersistent({
      scopeRoot: jobProject.root,
      artifactRoot: join(jobProject.root, 'browser'),
      settings: {
        workerEnv,
        ssrfFilter: renderedFetchRuntimeConfig.ssrfFilter
      }
    })
    sandbox = codexAppServerSandboxSpec({
      project: jobProject,
      materialized,
      runtimeFiles,
      workerEnv: codexWorkerEnv,
      ...(browserRuntimeMaterial ? { browserRuntime: browserSandboxRuntime(browserRuntimeMaterial) } : {})
    })
  } catch (error) {
    await browserRuntimeMaterial?.cleanup().catch(() => undefined)
    runtimeFiles.cleanup()
    throw error
  }

  let cleaned = false
  const cleanup = async (): Promise<void> => {
    if (cleaned) return
    cleaned = true
    let firstError: unknown
    try {
      await browserRuntimeMaterial?.cleanup()
    } catch (error) {
      firstError = error
    }
    try {
      runtimeFiles.cleanup()
    } catch (error) {
      firstError ??= error
    }
    if (firstError) throw firstError
  }

  return {
    turnStart,
    opts,
    jobID,
    job,
    jobProject,
    mcpServers,
    runtimeConfig,
    materialized,
    projectConfig,
    projection,
    runtimeFiles,
    sandbox,
    preparedAgentPlugins,
    cleanup
  }
}

export type PreparedCodexJobExecution = Awaited<ReturnType<typeof prepareCodexJobExecution>>

function selectCurrentStandaloneSkills(names: string[], available: RuntimeSkillSummary[]): RuntimeSkillSummary[] {
  const byName = new Map<string, RuntimeSkillSummary>()
  for (const skill of available) {
    if (skill.agentPluginId) continue
    if (!skill.skillName || byName.has(skill.skillName)) {
      throw new Error(`Agent conversation Skill catalog has duplicate or invalid name: ${skill.skillName || '<empty>'}`)
    }
    byName.set(skill.skillName, skill)
  }
  return [...names].sort(compareCodePoints).map(name => {
    const skill = byName.get(name)
    if (!skill) throw new Error(`BackgroundAgentJob Skill is unavailable: ${name}`)
    return skill
  })
}

function selectCurrentAgentPlugins(
  selectedIDs: string[],
  available: AgentPluginCatalogEntry[]
): AgentPluginCatalogEntry[] {
  const byID = new Map<string, AgentPluginCatalogEntry>()
  for (const agentPlugin of available) {
    if (!agentPlugin.id || byID.has(agentPlugin.id)) {
      throw new Error(`Agent Plugin catalog has duplicate or invalid id: ${agentPlugin.id || '<empty>'}`)
    }
    byID.set(agentPlugin.id, agentPlugin)
  }
  return [...selectedIDs].sort(compareCodePoints).map(id => {
    const agentPlugin = byID.get(id)
    if (!agentPlugin) throw new Error(`Selected Agent Plugin is unavailable: ${id}`)
    return agentPlugin
  })
}

function selectCurrentAgentPluginSkills(
  selectedAgentPlugins: AgentPluginCatalogEntry[],
  available: RuntimeSkillSummary[]
): RuntimeSkillSummary[] {
  const byOwnerAndName = new Map<string, RuntimeSkillSummary>()
  for (const skill of available) {
    if (!skill.agentPluginId) continue
    const key = `${skill.agentPluginId}\0${skill.skillName}`
    if (!skill.skillName || byOwnerAndName.has(key)) {
      throw new Error(
        `Agent conversation Plugin Skill catalog has duplicate or invalid member: ${skill.agentPluginId}/${skill.skillName || '<empty>'}`
      )
    }
    byOwnerAndName.set(key, skill)
  }
  return selectedAgentPlugins.flatMap(agentPlugin =>
    [...agentPlugin.skills]
      .sort((left, right) => compareCodePoints(left.catalogName, right.catalogName))
      .map(member => {
        const skill = byOwnerAndName.get(`${agentPlugin.id}\0${member.catalogName}`)
        if (!skill)
          throw new Error(`Current Agent Plugin Skill is unavailable: ${agentPlugin.id}/${member.catalogName}`)
        return skill
      })
  )
}

async function requestProjectionAIGatewayKey(
  turnStart: TurnStart,
  opts: CodexJobOptions,
  options?: { forceRefresh?: boolean }
): Promise<AIGatewayAPIKeyResponse> {
  return await opts.requestAIGatewayAPIKey(turnStart.turn.actor.agent_uid, options)
}

function jobWorkspaceMounts(job: BackgroundAgentJobResponse): CodexJobWorkspaceMountInput[] {
  return job.workspaceMounts.map(mount => {
    if (mount.access !== 'read_only' && mount.access !== 'read_write') {
      throw new Error(`invalid workspace mount access: ${mount.access}`)
    }
    return { id: mount.id, source: mount.source, access: mount.access }
  })
}

function compareCodePoints(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0
}
