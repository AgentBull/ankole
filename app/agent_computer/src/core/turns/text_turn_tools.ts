import type { TurnStart } from '../../lanes/actor_lane'
import {
  brainRPCRequester,
  rpcMethods,
  scheduleRPCRequester,
  signalChannelRPCRequester,
  type RPCRequester,
  type RuntimeSkillSummary
} from '../../lanes/rpc_lane'
import { createBrainTools } from '../../tools/brain/brain-tools'
import { createComputerTools } from '../../tools/computer'
import { createCreateBackgroundJobTool } from '../../tools/background-agent-job/create-background-job'
import { createListBackgroundJobsTool } from '../../tools/background-agent-job/list-background-jobs'
import { createRespawnBackgroundJobTool } from '../../tools/background-agent-job/respawn-background-job'
import { createSendMessageToBackgroundJobTool } from '../../tools/background-agent-job/send-message-to-background-job'
import { createShowBackgroundJobDetailsTool } from '../../tools/background-agent-job/show-background-job-details'
import { createStopBackgroundJobTool } from '../../tools/background-agent-job/stop-background-job'
import { createStandingOrdersTools } from '../../tools/channel/standing-orders-tool'
import { createClarifyTool } from '../../tools/clarify/clarify-tool'
import { createSkillTools, type SkillFileRoots } from '../../tools/library/skill-tools'
import { createScheduleTools } from '../../tools/schedule/schedule-tools'
import { createTodoTool, TodoStore } from '../../tools/todo/todo-tool'
import type { WorkerAgentTool } from '../types'
import { webSearchIsProviderHosted } from './turn_runtime_policy'

type TextTurnToolsOptions = {
  turnStart: TurnStart
  agentsRoot: string
  agentHome: string
  workspaceRoot: string
  userFilesRoot: string
  enabledSkills: Array<RuntimeSkillSummary | string>
  skillRoots: SkillFileRoots
  /** Per-turn `brain.enabled` resolution; false leaves the Brain tools unregistered. */
  brainEnabled: boolean
  rpc: RPCRequester
  waitForSteering?: (signal?: AbortSignal) => Promise<void>
  workerEnv: Record<string, string>
  runtimeEnv: Record<string, string>
  webTools: WorkerAgentTool[]
  runStep: <T>(promise: Promise<T>, step: string) => Promise<T>
}

/**
 * Owns the model-visible tool catalog for Text Turns.
 * Provider-hosted search removes only the local web_search tool.
 * Brain memory tools register only when `brain.enabled` resolved true.
 */
export async function createTextTurnTools(opts: TextTurnToolsOptions): Promise<WorkerAgentTool[]> {
  const turnStart = opts.turnStart
  const computerTools = createComputerTools({
    agentUID: turnStart.turn.actor.agent_uid,
    agentHome: opts.agentHome,
    workspaceRoot: opts.workspaceRoot,
    userFilesRoot: opts.userFilesRoot,
    workerEnv: opts.workerEnv,
    runtimeEnv: opts.runtimeEnv
  })
  const backgroundAgentJobTools = await opts.runStep(
    resolveBackgroundAgentJobTools(opts),
    'background agent job tool availability'
  )

  return [
    createTodoTool(new TodoStore()),
    ...computerTools,
    ...createScheduleTools({
      turnStart,
      requestScheduleRPC: scheduleRPCRequester(opts.rpc, turnStart.turn)
    }),
    ...createStandingOrdersTools({
      turnStart,
      requestSignalChannelRPC: signalChannelRPCRequester(opts.rpc, turnStart.turn)
    }),
    ...(opts.brainEnabled ? createBrainTools({ requestBrainRPC: brainRPCRequester(opts.rpc, turnStart.turn) }) : []),
    ...opts.webTools.filter(tool => !webSearchIsProviderHosted(turnStart) || tool.name !== 'web_search'),
    createClarifyTool(),
    ...backgroundAgentJobTools,
    ...createSkillTools({
      turn: turnStart.turn,
      enabledSkills: opts.enabledSkills,
      skillRoots: opts.skillRoots,
      rpc: opts.rpc
    })
  ]
}

async function resolveBackgroundAgentJobTools(opts: TextTurnToolsOptions): Promise<WorkerAgentTool[]> {
  const turnStart = opts.turnStart
  const response = await opts.rpc(rpcMethods.agentPluginList, {}, { turn: turnStart.turn })

  return [
    createCreateBackgroundJobTool({ turnStart, agentPluginCatalog: response.agentPlugins, rpc: opts.rpc }),
    createListBackgroundJobsTool({ turnStart, rpc: opts.rpc }),
    createShowBackgroundJobDetailsTool({ turnStart, rpc: opts.rpc }),
    createSendMessageToBackgroundJobTool({
      turnStart,
      rpc: opts.rpc,
      waitForSteering: opts.waitForSteering
    }),
    createRespawnBackgroundJobTool({ turnStart, agentsRoot: opts.agentsRoot, rpc: opts.rpc }),
    createStopBackgroundJobTool({ turnStart, rpc: opts.rpc })
  ]
}
