import { compareCodePointStrings } from '../../../common/ordering'
import type { TurnStart } from '../../../lanes/actor_lane'
import {
  brainRPCRequester,
  type AIGatewayAPIKeyResponse,
  type AgentPluginCatalogEntry,
  type BackgroundAgentJobResponse,
  type RuntimeSkillSummary
} from '../../../lanes/rpc_lane'
import { materializeCodexConfig } from '../runtime/agent-home-config'
import { resolveCodexRuntimeConfig } from '../runtime-config'
import { codexAgentRuntimeSandboxSpec, codexJobThreadEnv } from '../runtime/sandbox'
import {
  browserSandboxRuntime,
  withoutBrowserMaterialSourceEnv,
  type MaterializedBrowserRuntime
} from '../../../browser-runtime'
import { httpClientFromAIGatewayAPIKey } from '../../ai_gateway_transport'
import { resolveAgentConversationContext } from '../../turns/turn_context'
import { resolveBrainEnabled } from '../../turns/brain_context'
import { resolveRenderedFetchRuntimeConfig } from '../../turns/rendered_fetch_runtime_config'
import { createTurnWebTools } from '../../turns/turn_web_tools'
import { createBrainJobTools } from '../../../tools/brain/brain-tools'
import { createSkillTools } from '../../../tools/library/skill-tools'
import {
  materializeLarkCredential,
  sameLarkBindingIdentity,
  withoutLarkTenantToken,
  withoutLarkTenantTokenValue,
  type MaterializedLarkCredential
} from '../../execution/lark-credential'
import { resolveAgentWorkerEnvParts } from '../../execution/worker_env'
import { webSearchIsProviderHosted } from '../../turns/turn_runtime_policy'
import type { CodexJobOptions } from '../../turns/turn_options'
import { join } from 'node:path'
import { prepareAgentPlugins } from '../runtime/agent-plugin-materializer'
import { assertCodexJobProjectResumeState, codexJobProjectLocation, prepareCodexJobProject } from './job-project'
import { parentInputToolSpec } from './parent-input'
import { materializeCodexJobProjectConfig, readCodexJobProjectConfig } from './project-config'
import { buildCodexJobProjection } from './projection'
import { migrateLegacyCodexJobSkillRoots, readCodexJobGuidance, renderCodexJobAgents } from './runtime-files'
import { skillAvailableInRuntime } from '../../../skills/effective-skill'
import { createSkillLoader } from '../../../skills/skill-loader'
import { loadEnabledSkillMCPServers, materializeMCPorterConfig } from '../../../tools/mcp'
import {
  decodeCodexJobRuntimeProjection,
  projectWorkerEnv,
  selectProjectedAgentPlugins,
  selectProjectedStandaloneSkills
} from './runtime-projection'
import { codexJobThreadConfig } from './thread-config'
import { turnTracePropagationFromTurnStart } from '../../../observability/turn-tracing'
import { formatSkillsForSystemPrompt, type SkillPromptEntry } from '../../../prompts/skills_prompt'
import { skillPromptEntryFromRuntime } from '../../../prompts/system_prompt'

export type CodexJobSetupInput = {
  turnStart: TurnStart
  opts: CodexJobOptions
  jobID: string
  job: BackgroundAgentJobResponse
}

/**
 * Materializes resources for one Job attempt.
 * It does not start the shared app-server or own a Codex thread.
 */
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
  const agentPluginCatalog = agentContext.agentPlugins ?? []
  const projectedAgentPlugins = selectProjectedAgentPlugins(runtimeProjection, agentPluginCatalog, availableSkills)
  const enabledAgentPlugins = projectedAgentPlugins.agentPlugins
  const agentPluginSkills = selectCurrentAgentPluginSkills(enabledAgentPlugins, projectedAgentPlugins.skills)
  const loadableSkills = [...enabledSkills, ...agentPluginSkills]
  const skillRoots = {
    builtinSkillsRoot: opts.builtinSkillsRoot,
    agentInstalledSkillsRoot: opts.agentInstalledSkillsRoot,
    ...(opts.internalSkillsRoot ? { internalSkillsRoot: opts.internalSkillsRoot } : {})
  }
  const loadedSkillNames = new Set<string>()
  const skillLoader = createSkillLoader({
    turn: turnStart.turn,
    enabledSkills: loadableSkills,
    skillRoots,
    rpc: opts.rpc,
    runtime: 'background_job',
    onSkillLoaded: name => loadedSkillNames.add(name)
  })
  const brainEnabled = await resolveBrainEnabled(turnStart, opts.rpc, opts.logger)
  opts.abortSignal?.throwIfAborted()
  const workspaceOwnerJobID = job.workspaceOwnerJobId
  if (!workspaceOwnerJobID) throw new Error('Background agent job is missing its workspace owner')
  const projectLocation = codexJobProjectLocation(opts.agentsRoot, job.agentUid, workspaceOwnerJobID)
  if (job.runtimeThreadId) assertCodexJobProjectResumeState(projectLocation.hostPath)
  const jobProject = prepareCodexJobProject({ jobProjectRoot: projectLocation.hostPath })
  const initializeProject = !job.runtimeThreadId
  const skillsPrompt = formatSkillsForSystemPrompt(
    loadableSkills.map(skill => skillPromptEntryFromRuntime(skill, 'background_job')).filter(isSkillPromptEntry)
  )
  const replaceLegacySkillThread = initializeProject
    ? false
    : migrateLegacyCodexJobSkillRoots({
        jobRoot: jobProject.root,
        runtimeThreadID: job.runtimeThreadId,
        skillsPrompt
      })
  const agentsContent = initializeProject
    ? renderCodexJobAgents({
        jobRoot: jobProject.root,
        soul: agentContext.soul ?? '',
        mission: agentContext.mission ?? '',
        jobGuidance: readCodexJobGuidance(opts.builtinSkillsRoot),
        skillsPrompt,
        lazySkillRouting: brainEnabled,
        timezone: agentContext.conversation?.timezone
      }).content
    : undefined
  const preparedAgentPlugins = prepareAgentPlugins({
    projectRoot: projectLocation.hostPath,
    agentPlugins: agentPluginCatalog,
    agentHome: opts.agentHome,
    libraryRoot: join(opts.builtinSkillsRoot, 'agent-plugins'),
    initializeProject,
    ...(initializeProject && job.workspaceTemplateId ? { workspaceTemplateId: job.workspaceTemplateId } : {}),
    ...(agentsContent ? { agentsContent } : {})
  })
  const skillMCPServers = await loadEnabledSkillMCPServers({
    enabledSkills: loadableSkills,
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
  // Agent policy decides whether the Worker exposes local web_search. The
  // hosted tool declaration decides whether Codex asks the Provider to run it.
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
  const brainTools = brainEnabled
    ? createBrainJobTools({ requestBrainRPC: brainRPCRequester(opts.rpc, turnStart.turn), skillLoader })
    : []
  const skillTools = createSkillTools({
    turn: turnStart.turn,
    enabledSkills: loadableSkills,
    skillRoots,
    rpc: opts.rpc,
    loader: skillLoader
  })
  const projectedTools = [
    ...baseWebTools.filter(tool => !providerHostedWebSearch || tool.name !== 'web_search'),
    ...brainTools,
    ...skillTools
  ]
  const projection = buildCodexJobProjection({ tools: projectedTools })
  projection.dynamicTools.push(parentInputToolSpec())
  const mcporterConfig = materializeMCPorterConfig(skillMCPServers, { directory: join(jobProject.root, 'temp') })
  let browserRuntimeMaterial: MaterializedBrowserRuntime | undefined
  let larkCredential: MaterializedLarkCredential | undefined
  let agentRuntimeSandbox: ReturnType<typeof codexAgentRuntimeSandboxSpec>
  let threadEnv: Record<string, string>
  try {
    opts.abortSignal?.throwIfAborted()
    // The thread environment uses the binding identity from the first
    // resolution. Resolve the credential again because the operator can rebind
    // the Lark app during setup. If identities differ, fetch a token for the
    // current binding.
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
    replaceLegacySkillThread,
    loadableSkills,
    skillLoader,
    takeLoadedSkillNames: () => {
      const names = [...loadedSkillNames]
      loadedSkillNames.clear()
      return names
    },
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

async function requestProjectionAIGatewayKey(
  turnStart: TurnStart,
  opts: CodexJobOptions,
  options?: { forceRefresh?: boolean }
): Promise<AIGatewayAPIKeyResponse> {
  return await opts.requestAIGatewayAPIKey(turnStart.turn.actor.agent_uid, options)
}

function isSkillPromptEntry(entry: SkillPromptEntry | null): entry is SkillPromptEntry {
  return entry !== null
}
