import { compareCodePointStrings } from '../../common/ordering'
import type { TurnStart } from '../../lanes/actor_lane'
import {
  rpcMethods,
  type AIGatewayAPIKeyResponse,
  type AgentPluginCatalogEntry,
  type BackgroundAgentJobResponse,
  type RuntimeSkillSummary
} from '../../lanes/rpc_lane'
import { materializeCodexConfig } from './agent-home-config'
import { resolveCodexRuntimeConfig } from './runtime-config'
import { codexAgentRuntimeSandboxSpec, codexJobThreadEnv } from './sandbox'
import {
  browserSandboxRuntime,
  withoutBrowserMaterialSourceEnv,
  type MaterializedBrowserRuntime
} from '../../browser-runtime'
import { httpClientFromAIGatewayAPIKey } from '../ai_gateway_transport'
import { resolveAgentConversationContext } from '../turns/turn_context'
import { createTurnWebTools, resolveRenderedFetchRuntimeConfig } from '../turns/rendered_fetch_runtime_config'
import {
  materializeLarkCredential,
  sameLarkBindingIdentity,
  withoutLarkTenantToken,
  withoutLarkTenantTokenValue,
  type MaterializedLarkCredential
} from '../turns/lark-credential'
import { resolveAgentWorkerEnvParts } from '../turns/worker_env'
import { webSearchIsProviderHosted } from '../turns/turn_runtime_policy'
import type { CodexJobOptions } from '../turns/turn_options'
import { join } from 'node:path'
import {
  createJobAgentPluginMaterials,
  prepareAgentPlugins,
  selectAgentPluginCapabilities
} from './agent-plugin-materializer'
import { assertCodexJobProjectResumeState, codexJobProjectLocation, prepareCodexJobProject } from './job-project'
import { parentInputToolSpec } from './parent-input'
import { materializeCodexJobProjectConfig, readCodexJobProjectConfig } from './project-config'
import { buildCodexJobProjection } from './projection'
import { materializeCodexJobRuntimeFiles, readCodexJobGuidance, renderCodexJobAgents } from './runtime-files'
import { skillAvailableInRuntime } from '../../skills/effective-skill'
import { loadEnabledSkillMCPServers, materializeMCPorterConfig } from '../../tools/mcp'
import {
  decodeCodexJobRuntimeProjection,
  projectWorkerEnv,
  selectProjectedAgentPlugins,
  selectProjectedStandaloneSkills
} from './runtime-projection'
import { codexJobThreadConfig } from './thread-config'
import { turnTracePropagationFromTurnStart } from '../../observability/turn-tracing'

export type CodexJobSetupInput = {
  turnStart: TurnStart
  opts: CodexJobOptions
  jobID: string
  job: BackgroundAgentJobResponse
}

export async function prepareCodexJobExecution(input: CodexJobSetupInput) {
  const { turnStart, opts, jobID, job } = input
  opts.abortSignal?.throwIfAborted()
  const runtimeProjection = decodeCodexJobRuntimeProjection(job)
  const agentContext = await resolveAgentConversationContext(turnStart, opts)
  opts.abortSignal?.throwIfAborted()
  const availableSkills = agentContext.skills ?? []
  const enabledSkills = selectCurrentStandaloneSkills(
    selectProjectedStandaloneSkills(runtimeProjection, availableSkills)
  )
  const agentPluginCatalogResponse = await opts.rpc(rpcMethods.agentPluginList, {}, { turn: turnStart.turn })
  opts.abortSignal?.throwIfAborted()
  const projectedAgentPlugins = selectProjectedAgentPlugins(
    runtimeProjection,
    agentPluginCatalogResponse.agentPlugins,
    availableSkills
  )
  const enabledAgentPlugins = projectedAgentPlugins.agentPlugins
  const agentPluginSkills = selectCurrentAgentPluginSkills(enabledAgentPlugins, projectedAgentPlugins.skills)
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
        timezone: agentContext.conversation?.timezone
      }).content
    : undefined
  const preparedAgentPlugins = prepareAgentPlugins({
    projectRoot: projectLocation.hostPath,
    agentPlugins: agentPluginCatalogResponse.agentPlugins,
    agentHome: opts.agentHome,
    libraryRoot: join(opts.builtinSkillsRoot, 'agent-plugins'),
    initializeProject,
    ...(initializeProject && job.workspaceTemplateId ? { workspaceTemplateId: job.workspaceTemplateId } : {}),
    ...(agentsContent ? { agentsContent } : {})
  })
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
    agentUID: job.agentUid
  })
  // Two different facts. The Agent's choice decides whether the Worker declares a
  // web_search tool; the hosted declaration says whether the Provider will really
  // run a search this turn, which is what Codex's own switch must follow.
  const providerHostedWebSearch = webSearchIsProviderHosted(turnStart)
  const hostedWebSearch = (turnStart.hosted_tools ?? []).some(tool => tool.type === 'web_search')
  materializeCodexJobProjectConfig({
    projectRoot: jobProject.root,
    hostedWebSearch
  })
  const projectionAPIKey = runtimeConfig.aiGatewayKey
  const turnTracePropagation = turnTracePropagationFromTurnStart(turnStart)
  opts.abortSignal?.throwIfAborted()
  const projectionAIGateway = httpClientFromAIGatewayAPIKey(
    projectionAPIKey,
    options => requestProjectionAIGatewayKey(turnStart, opts, options),
    turnTracePropagation
  )
  const renderedFetchRuntimeConfig = await resolveRenderedFetchRuntimeConfig(turnStart, opts.rpc)
  opts.abortSignal?.throwIfAborted()
  const bindingName = turnStart.actor_event.binding_name
  const resolvedWorkerEnv = await resolveAgentWorkerEnvParts(job.agentUid, opts.rpc, bindingName)
  const currentWorkerEnv = withoutLarkTenantToken(resolvedWorkerEnv)
  const workerEnv = withoutLarkTenantTokenValue(projectWorkerEnv(runtimeProjection, currentWorkerEnv))
  opts.abortSignal?.throwIfAborted()
  const codexWorkerEnv = withoutBrowserMaterialSourceEnv(workerEnv)
  const baseWebTools = await createTurnWebTools({
    aiGateway: projectionAIGateway,
    renderedFetchRuntimeConfig,
    workerEnv,
    workspaceRoot: jobProject.root,
    browserRuntime: opts.browserRuntime
  })
  opts.abortSignal?.throwIfAborted()
  const projectedTools = baseWebTools.filter(tool => !providerHostedWebSearch || tool.name !== 'web_search')
  const projection = buildCodexJobProjection({ tools: projectedTools })
  projection.dynamicTools.push(parentInputToolSpec())
  const runtimeFiles = await materializeCodexJobRuntimeFiles({
    turn: turnStart.turn,
    jobRoot: jobProject.root,
    agentSkillsRoot: join(opts.agentHome, 'runtime-materials', 'skills'),
    enabledSkills: [...enabledSkills, ...agentPluginSkills],
    projectSkillNames: enabledSkills.map(skill => skill.skillName),
    skillRoots,
    rpc: opts.rpc
  })
  const agentPluginMaterials = createJobAgentPluginMaterials({
    prepared: preparedAgentPlugins,
    selected: backgroundAgentPlugins,
    materializedRoot: join(jobProject.root, '.ankole', 'agent-plugins'),
    skillMaterialsRoot: join(opts.agentHome, 'runtime-materials', 'skills')
  })
  let selectedAgentPluginPackages
  try {
    selectedAgentPluginPackages = agentPluginMaterials.materialize()
  } catch (error) {
    runtimeFiles.cleanup()
    throw error
  }
  const agentPluginCapabilities = selectAgentPluginCapabilities(
    selectedAgentPluginPackages,
    backgroundAgentPlugins,
    runtimeProjection.agentPluginSelections
  )
  const mcporterConfig = materializeMCPorterConfig(skillMCPServers, { directory: join(jobProject.root, 'temp') })
  let browserRuntimeMaterial: MaterializedBrowserRuntime | undefined
  let larkCredential: MaterializedLarkCredential | undefined
  let agentRuntimeSandbox: ReturnType<typeof codexAgentRuntimeSandboxSpec>
  let threadEnv: Record<string, string>
  try {
    opts.abortSignal?.throwIfAborted()
    // The thread env carries the binding identity of the first resolve above,
    // because projectWorkerEnv overlays current binding vars. The credential
    // file must agree with that identity, so this second live resolve is
    // compared with the first resolve, not with the frozen projection. When
    // the operator rebound the Lark app between the two resolves, the token is
    // dropped and the file refresh fetches one for the current binding.
    const currentLarkWorkerEnv = await resolveAgentWorkerEnvParts(job.agentUid, opts.rpc, bindingName)
    opts.abortSignal?.throwIfAborted()
    larkCredential = materializeLarkCredential({
      agentUID: job.agentUid,
      agentHome: opts.agentHome,
      rpc: opts.rpc,
      bindingName,
      workerEnv: sameLarkBindingIdentity(resolvedWorkerEnv, currentLarkWorkerEnv)
        ? currentLarkWorkerEnv
        : withoutLarkTenantToken(currentLarkWorkerEnv)
    })
    browserRuntimeMaterial = await opts.browserRuntime?.materializePersistent({
      scopeRoot: jobProject.root,
      artifactRoot: join(jobProject.root, 'browser'),
      settings: {
        workerEnv,
        ssrfFilter: renderedFetchRuntimeConfig.ssrfFilter
      }
    })
    opts.abortSignal?.throwIfAborted()
    const browserSandbox = browserRuntimeMaterial ? browserSandboxRuntime(browserRuntimeMaterial) : undefined
    agentRuntimeSandbox = codexAgentRuntimeSandboxSpec({
      materialized,
      ...(opts.browserRuntime
        ? {
            browserRuntime: {
              root: opts.browserRuntime.materializer.root,
              socketPath: opts.browserRuntime.materializer.socketPath
            }
          }
        : {})
    })
    threadEnv = codexJobThreadEnv({
      materialized,
      workerEnv: { ...codexWorkerEnv, ...mcporterConfig.env },
      runtimeEnv: { ...opts.runtimeEnv, ...larkCredential.runtimeEnv },
      ...(browserSandbox ? { browserEnv: browserSandbox.env } : {})
    })
  } catch (error) {
    larkCredential?.cleanup()
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
    try {
      larkCredential?.cleanup()
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
    runtimeProjection,
    jobProject,
    mcpServers: skillMCPServers,
    runtimeConfig,
    materialized,
    projection,
    runtimeFiles,
    agentRuntimeSandbox,
    threadEnv,
    threadConfig: codexJobThreadConfig({
      cwd: jobProject.codexCwd,
      codexHome: materialized.codexHome,
      env: threadEnv,
      runtime: runtimeConfig,
      turnTracePropagation,
      projectConfig: readCodexJobProjectConfig(jobProject.root)
    }),
    preparedAgentPlugins,
    agentPluginCapabilities,
    agentPluginMaterials,
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
    .sort((left, right) => compareCodePointStrings(left.skillName, right.skillName))
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
        .sort((left, right) => compareCodePointStrings(left.catalogName, right.catalogName))
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
