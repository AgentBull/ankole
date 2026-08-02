import type { TurnStart } from '../../lanes/actor_lane'
import {
  memoryRPCRequester,
  rpcMethods,
  type AIGatewayAPIKeyResponse,
  type AgentPluginCatalogEntry,
  type BackgroundAgentJobResponse,
  type RuntimeSkillSummary
} from '../../lanes/rpc_lane'
import { materializeCodexConfig } from '../../tools/codex/config'
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
import { materializeAgentPluginSkillOverlays, prepareAgentPlugins } from './agent-plugin-materializer'
import { assertCodexJobProjectResumeState, codexJobProjectLocation, prepareCodexJobProject } from './job-project'
import { parentInputToolSpec } from './parent-input'
import { materializeCodexJobProjectConfig } from './project-config'
import { buildCodexJobProjection } from './projection'
import { materializeCodexJobRuntimeFiles, readCodexJobGuidance, renderCodexJobAgents } from './runtime-files'
import { skillAvailableInRuntime } from '../../skills/effective-skill'
import { loadEnabledSkillMCPServers, materializeMCPorterConfig } from '../../tools/mcp'

export type CodexJobSetupInput = {
  turnStart: TurnStart
  opts: CodexJobOptions
  jobID: string
  job: BackgroundAgentJobResponse
}

export async function prepareCodexJobExecution(input: CodexJobSetupInput) {
  const { turnStart, opts, jobID, job } = input
  opts.abortSignal?.throwIfAborted()
  const agentContext = await resolveAgentConversationContext(turnStart, opts)
  opts.abortSignal?.throwIfAborted()
  const availableSkills = agentContext.skills ?? []
  const enabledSkills = selectCurrentStandaloneSkills(availableSkills)
  const agentPluginCatalogResponse = await opts.rpc(rpcMethods.agentPluginList, {}, { turn: turnStart.turn })
  opts.abortSignal?.throwIfAborted()
  const enabledAgentPlugins = agentPluginCatalogResponse.agentPlugins
  const agentPluginSkills = selectCurrentAgentPluginSkills(enabledAgentPlugins, availableSkills)
  const backgroundAgentPlugins = projectBackgroundJobAgentPlugins(enabledAgentPlugins, agentPluginSkills)
  const skillRoots = {
    builtinSkillsRoot: opts.builtinSkillsRoot,
    agentInstalledSkillsRoot: opts.agentInstalledSkillsRoot,
    ...(opts.internalSkillsRoot ? { internalSkillsRoot: opts.internalSkillsRoot } : {})
  }
  const workspaceOwnerJobID = job.workspaceOwnerJobId
  if (!workspaceOwnerJobID) throw new Error('Background agent job is missing its workspace owner')
  const projectLocation = codexJobProjectLocation(opts.agentsRoot, job.agentUid, workspaceOwnerJobID)
  if (job.runtimeThreadId) assertCodexJobProjectResumeState(projectLocation.hostPath)
  const jobProject = prepareCodexJobProject({ jobProjectRoot: projectLocation.hostPath })
  const initializeProject = !job.runtimeThreadId
  const agentsContent = initializeProject
    ? renderCodexJobAgents({
        jobRoot: jobProject.root,
        soul: agentContext.soul ?? '',
        mission: agentContext.mission ?? '',
        jobGuidance: readCodexJobGuidance(opts.builtinSkillsRoot),
        brainSnapshot: agentContext.brainSnapshot,
        timezone: agentContext.conversation?.timezone
      }).content
    : undefined
  const preparedAgentPlugins = prepareAgentPlugins({
    projectRoot: projectLocation.hostPath,
    agentPlugins: backgroundAgentPlugins,
    initializeProject,
    ...(initializeProject && job.workspaceTemplateId ? { workspaceTemplateId: job.workspaceTemplateId } : {}),
    ...(agentsContent ? { agentsContent } : {})
  })
  await materializeAgentPluginSkillOverlays({
    prepared: preparedAgentPlugins,
    enabledSkills: agentPluginSkills,
    turn: turnStart.turn,
    rpc: opts.rpc
  })
  opts.abortSignal?.throwIfAborted()
  const skillMCPServers = await loadEnabledSkillMCPServers({
    enabledSkills: [...enabledSkills, ...agentPluginSkills],
    skillRoots,
    runtime: 'background_job'
  })
  opts.abortSignal?.throwIfAborted()
  const runtimeConfig = await resolveCodexRuntimeConfig({
    turnStart,
    agentUID: job.agentUid,
    requestAIGatewayAPIKey: opts.requestAIGatewayAPIKey
  })
  opts.abortSignal?.throwIfAborted()
  const materialized = materializeCodexConfig({
    agentsRoot: opts.agentsRoot,
    agentUID: job.agentUid,
    runtime: runtimeConfig
  })
  materializeCodexJobProjectConfig({
    projectRoot: jobProject.root,
    pluginsEnabled: backgroundAgentPlugins.length > 0,
    runtimeConfig
  })
  const projectionAPIKey = runtimeConfig.aiGatewayKey
  opts.abortSignal?.throwIfAborted()
  const projectionAIGateway = httpClientFromAIGatewayAPIKey(projectionAPIKey, options =>
    requestProjectionAIGatewayKey(turnStart, opts, options)
  )
  const renderedFetchRuntimeConfig = await resolveRenderedFetchRuntimeConfig(turnStart, opts.rpc)
  opts.abortSignal?.throwIfAborted()
  const workerEnv = await resolveWorkerEnv(turnStart, opts.rpc)
  opts.abortSignal?.throwIfAborted()
  const codexWorkerEnv = withoutBrowserMaterialSourceEnv(workerEnv)
  const baseWebTools = await createTurnWebTools({
    aiGateway: projectionAIGateway,
    renderedFetchRuntimeConfig,
    workerEnv,
    browserRuntime: opts.browserRuntime,
    abortSignal: opts.abortSignal
  })
  opts.abortSignal?.throwIfAborted()
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
    jobRoot: jobProject.root,
    enabledSkills,
    skillRoots,
    rpc: opts.rpc
  })
  const mcporterConfig = materializeMCPorterConfig(skillMCPServers)
  let browserRuntimeMaterial: MaterializedBrowserRuntime | undefined
  let sandbox: ReturnType<typeof codexAppServerSandboxSpec>
  try {
    opts.abortSignal?.throwIfAborted()
    browserRuntimeMaterial = await opts.browserRuntime?.materializePersistent({
      scopeRoot: jobProject.root,
      artifactRoot: join(jobProject.root, 'browser'),
      settings: {
        workerEnv,
        ssrfFilter: renderedFetchRuntimeConfig.ssrfFilter
      }
    })
    opts.abortSignal?.throwIfAborted()
    sandbox = codexAppServerSandboxSpec({
      project: jobProject,
      materialized,
      runtimeFiles,
      workerEnv: { ...codexWorkerEnv, ...mcporterConfig.env },
      runtimeEnv: opts.runtimeEnv,
      ...(browserRuntimeMaterial ? { browserRuntime: browserSandboxRuntime(browserRuntimeMaterial) } : {})
    })
  } catch (error) {
    await browserRuntimeMaterial?.cleanup().catch(() => undefined)
    mcporterConfig.cleanup()
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
    try {
      mcporterConfig.cleanup()
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
    mcpServers: skillMCPServers,
    runtimeConfig,
    materialized,
    projection,
    runtimeFiles,
    sandbox,
    preparedAgentPlugins,
    cleanup
  }
}

export type PreparedCodexJobExecution = Awaited<ReturnType<typeof prepareCodexJobExecution>>

function selectCurrentStandaloneSkills(available: RuntimeSkillSummary[]): RuntimeSkillSummary[] {
  const byName = new Map<string, RuntimeSkillSummary>()
  for (const skill of available) {
    if (skill.agentPluginId) continue
    if (!skill.skillName || byName.has(skill.skillName)) {
      throw new Error(`Agent conversation Skill catalog has duplicate or invalid name: ${skill.skillName || '<empty>'}`)
    }
    byName.set(skill.skillName, skill)
  }
  return [...byName.values()]
    .sort((left, right) => compareCodePoints(left.skillName, right.skillName))
    .filter(skill => skillAvailableInRuntime(skill, 'background_job'))
}

function selectCurrentAgentPluginSkills(
  enabledAgentPlugins: AgentPluginCatalogEntry[],
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
  return enabledAgentPlugins
    .flatMap(agentPlugin =>
      [...agentPlugin.skills]
        .sort((left, right) => compareCodePoints(left.catalogName, right.catalogName))
        .map(member => {
          const skill = byOwnerAndName.get(`${agentPlugin.id}\0${member.catalogName}`)
          if (!skill) {
            throw new Error(`Current Agent Plugin Skill is unavailable: ${agentPlugin.id}/${member.catalogName}`)
          }
          return skill
        })
    )
    .filter(skill => skillAvailableInRuntime(skill, 'background_job'))
}

function projectBackgroundJobAgentPlugins(
  enabledAgentPlugins: AgentPluginCatalogEntry[],
  agentPluginSkills: RuntimeSkillSummary[]
): AgentPluginCatalogEntry[] {
  const selectedSkillKeys = new Set(agentPluginSkills.map(skill => `${skill.agentPluginId}\0${skill.skillName}`))

  return enabledAgentPlugins.map(agentPlugin => ({
    ...agentPlugin,
    skills: agentPlugin.skills.filter(skill => selectedSkillKeys.has(`${agentPlugin.id}\0${skill.catalogName}`))
  }))
}

async function requestProjectionAIGatewayKey(
  turnStart: TurnStart,
  opts: CodexJobOptions,
  options?: { forceRefresh?: boolean }
): Promise<AIGatewayAPIKeyResponse> {
  return await opts.requestAIGatewayAPIKey(turnStart.turn.actor.agent_uid, options)
}

function compareCodePoints(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0
}
