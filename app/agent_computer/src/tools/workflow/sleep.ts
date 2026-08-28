import { ms } from '@agentbull/active-support'
import { z } from 'zod'
import { defineWorkerTool, type AgentToolResult, type WorkerAgentTool } from '../../core'
import { jsonToolResult } from '../../core/tool-result'
import type { ActorTurnRef } from '../../lanes/actor_lane'
import { rpcMethods, type RPCRequester } from '../../lanes/rpc_lane'

const MIN_WAKE_AFTER_MS = ms('1m')
const MAX_WAKE_AFTER_MS = ms('48h')

const SleepParams = z
  .object({
    wake_after_ms: z
      .number()
      .int()
      .min(MIN_WAKE_AFTER_MS)
      .max(MAX_WAKE_AFTER_MS)
      .describe('Guaranteed wake deadline in milliseconds. Events can wake the task earlier.'),
    note: z
      .string()
      .min(1)
      .max(200)
      .describe('What this task waits for. The main Agent sees this note in show_workflow.'),
    attention: z
      .boolean()
      .default(false)
      .describe('Set true only when the task cannot proceed without main-Agent input.')
  })
  .strict()

type SleepDetails = {
  task_status: string
  wake_count: number
}

export type CreateWorkflowSleepToolOptions = {
  callId: string
  rpc: RPCRequester
  turn: ActorTurnRef
  onSleeping: () => void
}

/** Parks the Workflow task as a durable sleeping call and ends this turn. */
export function createWorkflowSleepTool(
  opts: CreateWorkflowSleepToolOptions
): WorkerAgentTool<typeof SleepParams, SleepDetails> {
  return defineWorkerTool({
    name: 'sleep',
    description: [
      'Hibernate this Workflow task and end the current turn. The task stays non-terminal and holds no worker slot.',
      'Any of these wakes it into a new turn with this conversation intact: the wake_after_ms deadline, a message from the main Agent, or a lifecycle event from a background job this task created.',
      'Sleep after create_background_job instead of waiting in this turn.',
      'The wake budget is bounded, so sleep for the expected wait instead of polling with short sleeps.'
    ].join(' '),
    schema: SleepParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: false,
    describeActivity: () => ({ key: 'signals_gateway.reply.activity.workflow_task_sleep' }),
    async execute(_toolCallID, params): Promise<AgentToolResult<SleepDetails>> {
      const response = await opts.rpc(
        rpcMethods.workflowTaskSleep,
        {
          callId: opts.callId,
          wakeAfterMs: BigInt(params.wake_after_ms),
          note: params.note,
          attention: params.attention
        },
        { turn: opts.turn }
      )
      if (response.taskStatus !== 'sleeping' && response.taskStatus !== 'cancelled') {
        throw new Error(`Workflow task sleep returned invalid status: ${response.taskStatus || '<empty>'}`)
      }
      opts.onSleeping()
      return jsonToolResult({ task_status: response.taskStatus, wake_count: response.wakeCount }, { terminate: true })
    }
  })
}
