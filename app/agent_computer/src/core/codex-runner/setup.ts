import type { TurnStart } from '../../lanes/actor_lane'
import {
  rpcMethods,
  type AIGatewayAPIKeyResponse,
  type AgentPluginCatalogEntry,
  type BackgroundAgentJobResponse,
  type MemoryRPCMethod,
  type RPCSchemaByMethod,
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
import { codexJobProjectLocation, prepareCodexJobProject } from './job-project'
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
    { agent_uid: job.agent_uid, session_id: job.owner_session_id }
  )
  const agentContext = await resolveAgentConversationContext(turnStart, opts)
  const availableSkills = agentContext.skills ?? []
  const enabledSkills = selectCurrentStandaloneSkills(job.skill_names, availableSkills)
  const agentPluginCatalogResponse = await opts.rpc(rpcMethods.agentPluginList, { turn: turnStart.turn })
  const selectedAgentPlugins = selectCurrentAgentPlugins(job.agent_plugin_ids, agentPluginCatalogResponse.agent_plugins)
  const agentPluginSkills = selectCurrentAgentPluginSkills(selectedAgentPlugins, availableSkills)
  const skillRoots = {
    builtinSkillsRoot: opts.builtinSkillsRoot,
    agentInstalledSkillsRoot: opts.agentInstalledSkillsRoot,
    ...(opts.internalSkillsRoot ? { internalSkillsRoot: opts.internalSkillsRoot } : {})
  }
  const projectLocation = codexJobProjectLocation(opts.userFilesRoot, jobID)
  if (job.runtime_thread_id) assertAgentPluginProjectResumeState(projectLocation.hostPath)

  // Validate every caller-owned mount before Agent Plugin recovery may rebuild
  // the private project that sits beside those mounts.
  const preflightProject = prepareCodexJobProject({
    jobProjectRoot: projectLocation.hostPath,
    ownerModelPath: projectLocation.ownerModelPath,
    ownerWorkspaceRoot: parentWorkspaceRoot,
    allowedSourceRoots: [opts.userFilesRoot],
    workspaceMounts: job.workspace_mounts
  })
  const initializeProject = !job.runtime_thread_id
  const agentsContent = initializeProject
    ? renderCodexJobAgents({
        guidanceWorkspaceRoot: parentWorkspaceRoot,
        workspaceMounts: preflightProject.workspaceMounts,
        soul: agentContext.soul ?? '',
        mission: agentContext.mission ?? '',
        brainSnapshot: agentContext.brain_snapshot,
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
    workspaceMounts: job.workspace_mounts
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
      ...(job.reasoning_effort ? { reasoningEffort: job.reasoning_effort } : {})
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
    ...createMemoryTools({
      turnStart,
      // Memory operations issued inside the job are re-scoped to the owning
      // session so Brain attributes them to the job, not the parent turn.
      requestMemoryRPC: <M extends MemoryRPCMethod>(
        method: M,
        payload: Omit<RPCSchemaByMethod[M]['request'], 'request_id'>
      ) =>
        opts.rpc(method, {
          ...payload,
          job_id: jobID,
          job_scope: {
            session_id: job.owner_session_id,
            signal_channel_id: stringValue(job.reply_route.signal_channel_id)
          }
        })
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
    if (skill.agent_plugin_id) continue
    if (!skill.skill_name || byName.has(skill.skill_name)) {
      throw new Error(
        `Agent conversation Skill catalog has duplicate or invalid name: ${skill.skill_name || '<empty>'}`
      )
    }
    byName.set(skill.skill_name, skill)
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
    if (!skill.agent_plugin_id) continue
    const key = `${skill.agent_plugin_id}\0${skill.skill_name}`
    if (!skill.skill_name || byOwnerAndName.has(key)) {
      throw new Error(
        `Agent conversation Plugin Skill catalog has duplicate or invalid member: ${skill.agent_plugin_id}/${skill.skill_name || '<empty>'}`
      )
    }
    byOwnerAndName.set(key, skill)
  }
  return selectedAgentPlugins.flatMap(agentPlugin =>
    [...agentPlugin.skills]
      .sort((left, right) => compareCodePoints(left.catalog_name, right.catalog_name))
      .map(member => {
        const skill = byOwnerAndName.get(`${agentPlugin.id}\0${member.catalog_name}`)
        if (!skill)
          throw new Error(`Current Agent Plugin Skill is unavailable: ${agentPlugin.id}/${member.catalog_name}`)
        return skill
      })
  )
}

async function requestProjectionAIGatewayKey(
  turnStart: TurnStart,
  opts: CodexJobOptions,
  options?: { forceRefresh?: boolean }
): Promise<AIGatewayAPIKeyResponse> {
  return await opts.requestAIGatewayAPIKey({ agent_uid: turnStart.turn.actor.agent_uid }, options)
}

function compareCodePoints(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0
}
