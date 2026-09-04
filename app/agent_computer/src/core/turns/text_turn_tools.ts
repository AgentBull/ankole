import type { TurnStart } from '../../lanes/actor_lane'
import {
  scheduleRPCRequester,
  signalChannelRPCRequester,
  type AgentPluginCatalogEntry,
  type RPCRequester,
  type RuntimeSkillSummary
} from '../../lanes/rpc_lane'
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
import { createCancelWorkflowTool } from '../../tools/workflow/cancel-workflow'
import { createListWorkflowsTool } from '../../tools/workflow/list-workflows'
import { createSendMessageToWorkflowTaskTool } from '../../tools/workflow/send-message-to-workflow-task'
import { createShowWorkflowTool } from '../../tools/workflow/show-workflow'
import { createWorkflowTool } from '../../tools/workflow/workflow'
import type { WorkerAgentTool } from '../types'
import { createSkillLoader } from '../../skills/skill-loader'

type TextTurnToolsOptions = {
  turnStart: TurnStart
  agentsRoot: string
  agentHome: string
  workspaceRoot: string
  userFilesRoot: string
  enabledSkills: RuntimeSkillSummary[]
  agentPluginCatalog: AgentPluginCatalogEntry[]
  skillRoots: SkillFileRoots
  rpc: RPCRequester
  waitForSteering?: (signal?: AbortSignal) => Promise<void>
  workerEnv: Record<string, string>
  runtimeEnv: Record<string, string>
  webTools: WorkerAgentTool[]
}

/**
 * Owns the model-visible local tool catalog for Text Turns. The web tools
 * arrive already projected by createTurnWebTools. Brain memory is an
 * AIGateway-hosted tool and never registers here.
 */
export function createTextTurnTools(opts: TextTurnToolsOptions): WorkerAgentTool[] {
  const turnStart = opts.turnStart
  const computerTools = createComputerTools({
    agentHome: opts.agentHome,
    workspaceRoot: opts.workspaceRoot,
    userFilesRoot: opts.userFilesRoot,
    workerEnv: opts.workerEnv,
    runtimeEnv: opts.runtimeEnv
  })
  const backgroundAgentJobTools = createBackgroundAgentJobTools(opts)
  const skillLoader = createSkillLoader({
    turn: turnStart.turn,
    enabledSkills: opts.enabledSkills,
    skillRoots: opts.skillRoots,
    rpc: opts.rpc,
    runtime: 'main'
  })

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
    ...opts.webTools,
    createClarifyTool(),
    ...backgroundAgentJobTools,
    createWorkflowTool({ turnStart, rpc: opts.rpc }),
    createShowWorkflowTool({ turnStart, rpc: opts.rpc }),
    createListWorkflowsTool({ turnStart, rpc: opts.rpc }),
    createSendMessageToWorkflowTaskTool({ turnStart, rpc: opts.rpc }),
    createCancelWorkflowTool({ turnStart, rpc: opts.rpc }),
    ...createSkillTools({
      turn: turnStart.turn,
      enabledSkills: opts.enabledSkills,
      skillRoots: opts.skillRoots,
      rpc: opts.rpc,
      loader: skillLoader
    })
  ]
}

function createBackgroundAgentJobTools(opts: TextTurnToolsOptions): WorkerAgentTool[] {
  const turnStart = opts.turnStart

  return [
    createCreateBackgroundJobTool({ turnStart, agentPluginCatalog: opts.agentPluginCatalog, rpc: opts.rpc }),
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
