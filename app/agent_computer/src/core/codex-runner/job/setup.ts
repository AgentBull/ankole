import type { TurnStart } from '../../../lanes/actor_lane'
import {
  type AIGatewayAPIKeyResponse,
  type BackgroundAgentJobResponse,
  type RuntimeSkillSummary
} from '../../../lanes/rpc_lane'
import { materializeCodexConfig } from '../runtime/agent-home-config'
import { resolveCodexRuntimeConfig } from '../runtime-config'
import { codexAgentRuntimeSandboxSpec, codexJobThreadEnv } from '../runtime/sandbox'
import { httpClientFromAIGatewayAPIKey } from '../../ai_gateway_transport'
import { resolveAgentConversationContext } from '../../turns/turn_context'
import { resolveRenderedFetchRuntimeConfig } from '../../turns/rendered_fetch_runtime_config'
import { createTurnWebTools } from '../../turns/turn_web_tools'
import { createSkillTools } from '../../../tools/library/skill-tools'
import { prepareExecutionMaterials } from '../../execution/execution-materials'
import type { CodexJobOptions } from '../../turns/turn_options'
import { join } from 'node:path'
import { prepareAgentPlugins, type PreparedAgentPlugins } from '../runtime/agent-plugin-materializer'
import type { AgentCodexRuntimeAcquireInput } from '../runtime/agent-runtime-manager'
import {
  assertCodexJobProjectResumeState,
  codexJobProjectLocation,
  prepareCodexJobProject,
  type PreparedCodexJobProject
} from './job-project'
import { parentInputToolSpec } from './parent-input'
import { materializeCodexJobProjectConfig, readCodexJobProjectConfig } from './project-config'
import { buildCodexJobProjection, type CodexJobProjection } from './projection'
import { migrateLegacyCodexJobSkillRoots, readCodexJobGuidance, renderCodexJobAgents } from './runtime-files'
import { createSkillLoader, type SkillLoader } from '../../../skills/skill-loader'
import { loadEnabledSkillMCPServers, type MCPServerConfig } from '../../../tools/mcp'
import { decodeCodexJobRuntimeProjection, projectWorkerEnv, selectJobSkills } from './runtime-projection'
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
 * Resources that setup produces for one Job attempt. The session adds the
 * caller's own inputs (turn, options, Job) and the model binding it derives
 * from the turn.
 */
export type PreparedCodexJobExecution = {
  runtimeAcquire: Omit<AgentCodexRuntimeAcquireInput, 'logger' | 'abortSignal'>
  threadConfig: Record<string, unknown>
  projection: CodexJobProjection
  skills: {
    loadable: RuntimeSkillSummary[]
    loader: SkillLoader
    takeLoadedNames(): string[]
    mcpServers: MCPServerConfig[]
  }
  project: PreparedCodexJobProject
  replaceLegacySkillThread: boolean
  preparedAgentPlugins: PreparedAgentPlugins
  cleanup(): Promise<void>
}

/**
 * Materializes resources for one Job attempt.
 * It does not start the shared app-server or own a Codex thread.
 */
export async function prepareCodexJobExecution(input: CodexJobSetupInput): Promise<PreparedCodexJobExecution> {
  const { turnStart, opts, jobID, job } = input
  opts.abortSignal?.throwIfAborted()
  const runtimeProjection = decodeCodexJobRuntimeProjection(job)
  const agentContext = await resolveAgentConversationContext(turnStart, opts)
  opts.abortSignal?.throwIfAborted()
  const agentPluginCatalog = agentContext.agentPlugins ?? []
  const loadableSkills = selectJobSkills(runtimeProjection, {
    skills: agentContext.skills ?? [],
    agentPlugins: agentPluginCatalog
  })
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
  // The control plane declares the hosted brain tool only while `brain.enabled`
  // is true, so the declaration is the Job's memory switch.
  const brainEnabled = (turnStart.hosted_tools ?? []).some(tool => tool.type === 'brain')
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
  // The hosted tool declaration decides whether Codex asks the Provider to run
  // web search; createTurnWebTools decides whether the Worker exposes the local tool.
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
  let webTools: Awaited<ReturnType<typeof createTurnWebTools>> | undefined
  const materials = await prepareExecutionMaterials({
    agentUID: job.agentUid,
    agentHome: opts.agentHome,
    rpc: opts.rpc,
    bindingName,
    runtimeEnv: opts.runtimeEnv,
    mcpServers: skillMCPServers,
    mcporterDirectory: join(jobProject.root, 'temp'),
    projectEnv: workerEnv => projectWorkerEnv(runtimeProjection, workerEnv),
    consumeMaterialSourceEnv: async workerEnv => {
      webTools = await createTurnWebTools({
        turnStart,
        aiGateway: projectionAIGateway,
        renderedFetchRuntimeConfig,
        workerEnv,
        workspaceRoot: jobProject.root,
        repeatFetchSessionKey: jobID,
        browserRuntime: opts.browserRuntime
      })
    },
    ...(opts.browserRuntime
      ? {
          browser: {
            runtime: opts.browserRuntime,
            scopeRoot: jobProject.root,
            artifactRoot: join(jobProject.root, 'browser'),
            ssrfFilter: renderedFetchRuntimeConfig.ssrfFilter
          }
        }
      : {}),
    ...(opts.abortSignal ? { abortSignal: opts.abortSignal } : {})
  })

  try {
    if (!webTools) throw new Error('Codex Job execution materials did not prepare web tools')
    opts.abortSignal?.throwIfAborted()
    const skillTools = createSkillTools({
      turn: turnStart.turn,
      enabledSkills: loadableSkills,
      skillRoots,
      rpc: opts.rpc,
      loader: skillLoader
    })
    const projection = buildCodexJobProjection({ tools: [...webTools, ...skillTools] })
    projection.dynamicTools.push(parentInputToolSpec())

    const agentRuntimeSandbox = codexAgentRuntimeSandboxSpec({
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
    const threadEnv = codexJobThreadEnv({
      materialized,
      workerEnv: materials.workerEnv,
      runtimeEnv: materials.runtimeEnv,
      browserEnv: materials.browserEnv
    })

    return {
      runtimeAcquire: {
        agentUID: job.agentUid,
        agentHome: materialized.agentHome,
        codexHome: materialized.codexHome,
        aiGatewayBaseURL: runtimeConfig.aiGatewayKey.baseUrl,
        aiGatewayAPIKey: runtimeConfig.aiGatewayKey.apiKey,
        sandbox: agentRuntimeSandbox
      },
      threadConfig: codexJobThreadConfig({
        cwd: jobProject.root,
        codexHome: materialized.codexHome,
        env: threadEnv,
        runtime: runtimeConfig,
        turnTracePropagation,
        projectConfig: readCodexJobProjectConfig(jobProject.root)
      }),
      projection,
      skills: {
        loadable: loadableSkills,
        loader: skillLoader,
        takeLoadedNames: () => {
          const names = [...loadedSkillNames]
          loadedSkillNames.clear()
          return names
        },
        mcpServers: materials.mcpServers
      },
      project: jobProject,
      replaceLegacySkillThread,
      preparedAgentPlugins,
      cleanup: materials.cleanup
    }
  } catch (error) {
    await materials.cleanup().catch(() => undefined)
    throw error
  }
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
