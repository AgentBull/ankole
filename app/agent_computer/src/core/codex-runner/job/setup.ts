import { driveMounts, type DriveView } from '../../../drive/mounts'
import { materializeKnowledgeSkills } from '../../../skills/knowledge-skills'
import { HostedTool } from '../../../fabric/generated/ankole/runtime_fabric/v1/envelope_pb'
import type { TurnStart } from '../../../lanes/session_lane'
import {
  type BackgroundAgentJobResponse,
  type RuntimeSkillSummary
} from '../../../fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { materializeCodexConfig, migrateCodexSession } from '../runtime/agent-home-config'
import { resolveCodexRuntimeConfig } from '../runtime-config'
import { codexAppServerSpec, codexJobThreadEnv } from '../runtime/app-server-spec'
import { materializeAgentLibraryDocuments } from '../../agent-library-documents'
import { agentHomePaths } from '../../agent-home-paths'
import { createWebTools } from '../../../tools/web/web-tools'
import { webSearchIsProviderHosted } from '../../runtime-policy'
import { createSkillTools } from '../../../tools/library/skill-tools'
import { createPeerTools } from '../../../tools/library/peer-tools'
import { brainToolDeclarations, createBrainTools } from '../../../tools/library/brain-tools'
import { prepareExecutionMaterials } from '../../execution/execution-materials'
import type { CodexJobOptions } from '../options'
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
import { renderCodexJobAgents } from './runtime-files'
import { skillAvailableInRuntime } from '../../../skills/effective-skill'
import { createSkillLoader, type SkillLoader } from '../../../skills/skill-loader'
import { loadEnabledSkillMCPServers, type MCPServerConfig } from '../../../tools/mcp'
import { decodeCodexJobRuntimeProjection, projectWorkerEnv } from './runtime-projection'
import { codexJobThreadConfig } from './thread-config'
import { turnTracePropagationFromTurnStart } from '../../../observability/turn-tracing'

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
  driveView?: DriveView
  resumePath?: string
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
  preparedAgentPlugins: PreparedAgentPlugins
  cleanup(): Promise<void>
}

/**
 * Materializes resources for one Job attempt.
 * It does not start the shared app-server or own a Codex thread.
 */
export async function prepareCodexJobExecution(input: CodexJobSetupInput): Promise<PreparedCodexJobExecution> {
  const { turnStart, opts, job } = input
  opts.abortSignal?.throwIfAborted()
  const runtimeProjection = decodeCodexJobRuntimeProjection(job)
  if (!turnStart.agent_context) throw new Error('Job preparation requires the Agent context')
  let driveView: DriveView | undefined
  const documentPaths = agentHomePaths(opts.agentHome)
  if (turnStart.drive_vfs) documentPaths.codexHome = join(documentPaths.codexHome, 'scopes', turnStart.drive_vfs.view)
  const agentContext = materializeAgentLibraryDocuments(documentPaths, turnStart.agent_context)
  opts.abortSignal?.throwIfAborted()
  const agentPluginCatalog = agentContext.agentPlugins ?? []
  // The control plane selects the Job's Skills from its frozen choices and
  // renders their index.
  const selectedSkills = agentContext.skills ?? []
  // The Skill loader applies the `ankole-runtime` rule itself, as in the main
  // Agent. It gets every selected Skill so that it rejects a main-only Skill for
  // its runtime, not as a disabled Skill.
  const loadableSkills = selectedSkills.filter(skill => skillAvailableInRuntime(skill, 'background_job'))
  const materializedSkills = await materializeKnowledgeSkills({
    root: join(opts.agentHome, '.ankole', 'turn-skills', turnStart.turn.signal_id),
    frame: { jobTurn: turnStart.turn },
    skills: loadableSkills,
    rpc: opts.rpc
  })
  let cleanupMaterials: (() => Promise<void>) | undefined
  try {
    driveView = await driveMounts.acquire(turnStart.drive_vfs)
    const skillRoots = {
      builtinSkillsRoot: materializedSkills.root,
      agentInstalledSkillsRoot: materializedSkills.root
    }
    const loadedSkillNames = new Set<string>()
    const skillLoader = createSkillLoader({
      turn: turnStart.turn,
      enabledSkills: selectedSkills,
      rpc: opts.rpc,
      onSkillLoaded: name => loadedSkillNames.add(name)
    })
    // The turn start carries the Brain read declarations only while
    // `brain.enabled` is true, so that list is the Job's memory switch. Code mode
    // calls only the tools Codex declared, so the Job projects the control-plane
    // declarations as its own dynamic tools and the read-tool owner executes them.
    const brainTools = createBrainTools({
      turn: turnStart.turn,
      rpc: opts.rpc,
      declarations: brainToolDeclarations(turnStart.request_context)
    })
    opts.abortSignal?.throwIfAborted()
    const workspaceOwnerJobID = job.workspaceOwnerJobId
    if (!workspaceOwnerJobID) throw new Error('Background agent job is missing its workspace owner')
    const projectLocation = codexJobProjectLocation(opts.agentHome, workspaceOwnerJobID)
    if (job.runtimeThreadId) assertCodexJobProjectResumeState(projectLocation.hostPath)
    const jobProject = prepareCodexJobProject({ jobProjectRoot: projectLocation.hostPath })
    const initializeProject = !job.runtimeThreadId
    const skillsPrompt = agentContext.skillsPrompt
    const jobInstructions = renderCodexJobAgents({
      jobRoot: jobProject.root,
      skillsPrompt,
      podInstructions: agentContext.conversation?.podInstructions,
      driveInstructions: agentContext.driveInstructions,
      timezone: agentContext.conversation?.timezone
    }).content
    const materialized = materializeCodexConfig({
      agentHomeRoot: opts.agentHome,
      viewKey: driveView?.key
    })
    const resumePath =
      driveView && job.runtimeThreadId
        ? await migrateCodexSession(opts.agentHome, materialized.codexHome, job.runtimeThreadId)
        : undefined
    const preparedAgentPlugins = prepareAgentPlugins({
      projectRoot: projectLocation.hostPath,
      agentPlugins: agentPluginCatalog,
      codexHome: materialized.codexHome,
      libraryRoot: join(opts.builtinSkillsRoot, 'agent-plugins'),
      initializeProject,
      ...(initializeProject && job.workspaceTemplateId ? { workspaceTemplateId: job.workspaceTemplateId } : {})
    })
    const skillMCPServers = await loadEnabledSkillMCPServers({
      enabledSkills: materializedSkills.skills,
      skillRoots,
      runtime: 'background_job'
    })
    opts.abortSignal?.throwIfAborted()
    const runtimeConfig = await resolveCodexRuntimeConfig({
      turnStart,
      requestAIGatewayAPIKey: opts.requestAIGatewayAPIKey
    })
    opts.abortSignal?.throwIfAborted()
    // The hosted tool declaration decides whether Codex asks the Provider to run
    // web search. The Agent policy decides whether the Worker exposes the local tool.
    const hostedWebSearch = (turnStart.hosted_tools ?? []).includes(HostedTool.WEB_SEARCH)
    materializeCodexJobProjectConfig({
      projectRoot: jobProject.root,
      hostedWebSearch
    })
    const turnTracePropagation = turnTracePropagationFromTurnStart(turnStart)
    opts.abortSignal?.throwIfAborted()
    const renderedFetchRuntimeConfig = turnStart.fetch_runtime_config
    opts.abortSignal?.throwIfAborted()
    const bindingName = turnStart.signal.binding_name
    const materials = await prepareExecutionMaterials({
      agentHome: opts.agentHome,
      rpc: opts.rpc,
      bindingName,
      runtimeEnv: opts.runtimeEnv,
      mcpServers: skillMCPServers,
      mcporterDirectory: join(jobProject.root, 'temp'),
      projectEnv: workerEnv => projectWorkerEnv(runtimeProjection, workerEnv),
      ...(opts.browserRuntime
        ? {
            renderedFetch: { config: renderedFetchRuntimeConfig, browserRuntime: opts.browserRuntime },
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
    cleanupMaterials = materials.cleanup
    opts.abortSignal?.throwIfAborted()
    const webTools = (
      await createWebTools({
        rpc: opts.rpc,
        turn: turnStart.turn,
        renderedFallback: materials.renderedFetch
      })
    ).filter(tool => tool.name !== 'web_search' || !webSearchIsProviderHosted(turnStart))
    const skillTools = createSkillTools({
      turn: turnStart.turn,
      enabledSkills: loadableSkills,
      rpc: opts.rpc,
      loader: skillLoader
    })
    const peerTools = createPeerTools({
      rpc: opts.rpc,
      turn: turnStart.turn,
      requestContext: turnStart.request_context
    })
    const projection = buildCodexJobProjection({ tools: [...webTools, ...skillTools, ...brainTools, ...peerTools] })
    projection.dynamicTools.push(parentInputToolSpec())

    const threadEnv = codexJobThreadEnv({
      materialized,
      workerEnv: materials.workerEnv,
      runtimeEnv: materials.runtimeEnv,
      browserEnv: materials.browserEnv
    })

    return {
      driveView,
      resumePath,
      runtimeAcquire: {
        agentUID: job.agentUid,
        driveView,
        agentHome: materialized.agentHome,
        codexHome: materialized.codexHome,
        sqliteHome: materialized.sqliteHome,
        aiGatewayBaseURL: runtimeConfig.aiGatewayKey.baseUrl,
        aiGatewayAPIKey: runtimeConfig.aiGatewayKey.apiKey,
        appServer: codexAppServerSpec(materialized)
      },
      threadConfig: codexJobThreadConfig({
        cwd: jobProject.root,
        jobInstructions,
        codexHome: materialized.codexHome,
        env: threadEnv,
        runtime: runtimeConfig,
        job: { jobID: turnStart.turn.job_id, attempt: turnStart.turn.attempt, signalID: turnStart.turn.signal_id },
        podInstructions: agentContext.conversation?.podInstructions,
        relatedContext:
          typeof turnStart.request_context?.related_context_index === 'string'
            ? turnStart.request_context.related_context_index
            : undefined,
        originalHumanRequest:
          typeof turnStart.request_context?.original_human_request === 'string'
            ? turnStart.request_context.original_human_request
            : undefined,
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
      preparedAgentPlugins,
      cleanup: async () => {
        try {
          await materials.cleanup()
        } finally {
          await materializedSkills.cleanup()
          await driveView?.release()
        }
      }
    }
  } catch (error) {
    await driveView?.release().catch(() => undefined)
    await cleanupMaterials?.().catch(() => undefined)
    await materializedSkills.cleanup().catch(() => undefined)
    throw error
  }
}
