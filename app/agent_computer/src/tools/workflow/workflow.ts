import { utf8ByteLength } from '../../common/text-sanitize'
import { defineWorkerTool, type WorkerAgentTool } from '../../core'
import {
  availableCustomModelProfiles,
  customModelProfileDescription,
  customModelProfileSchema,
  type CustomModelProfile
} from '../../core/custom-model-profiles'
import { modelIntegerIDFromWire } from '../../core/model-integer-id'
import { jsonToolResult } from '../../core/tool-result'
import { jsonBytes } from '../../fabric/envelope_proto'
import type { TurnStart } from '../../lanes/actor_lane'
import { rpcMethods, type RPCRequester, type RPCRequestInit } from '../../lanes/rpc_lane'
import { z } from 'zod'

const WORKFLOW_SCRIPT_MAX_BYTES = 262_144
const WORKFLOW_ARGS_MAX_BYTES = 65_536
const WorkflowStatusSchema = z.enum(['running', 'completed', 'failed', 'cancelled'])

type WorkflowParams = {
  title: string
  script: string
  args?: Record<string, unknown>
  concurrency?: number
  max_agent_calls?: number
  model_profile?: string
}

type CreateWorkflowResult = {
  run_id: number
  status: z.infer<typeof WorkflowStatusSchema>
}

export type WorkflowToolOptions = {
  turnStart: TurnStart
  rpc: RPCRequester
}

export function createWorkflowTool(
  opts: WorkflowToolOptions
): WorkerAgentTool<ReturnType<typeof workflowParamsSchema>, CreateWorkflowResult> {
  const customModelProfiles = availableCustomModelProfiles(opts.turnStart)

  return defineWorkerTool({
    name: 'workflow',
    description: [
      'Run a bounded JavaScript orchestration that fans work out to independent subagents and wakes this conversation when the run finishes.',
      'The script starts with its persisted input object as args and calls await agent(prompt, { label?, model_profile?, schema? }); a successful call resolves to its structured value and a failed call resolves to null.',
      'Use Promise.all for parallel fanout, handle null explicitly, and return the final value from the script.',
      'Each attempt is one real subagent turn; one agent() call can use up to three attempts, so give each call a meaningful task and set concurrency and max_agent_calls deliberately.',
      'The script must terminate: use finite input arrays and explicit loop bounds, and do not poll or wait for external state.',
      'A result schema must use the supported OpenAPI-compatible JSON Schema subset and cannot allow null. Every object must set additionalProperties to false and list every property name in required.',
      customModelProfileDescription(customModelProfiles, 'primary')
    ].join(' '),
    schema: workflowParamsSchema(customModelProfiles),
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: false,
    describeActivity: () => ({ key: 'signals_gateway.reply.activity.workflow_create' }),
    async execute(toolCallID, params) {
      const request: RPCRequestInit<'workflow.create'> = {
        sourceToolCallId: toolCallID,
        title: params.title.trim(),
        script: params.script,
        argsJson: jsonBytes(params.args ?? {}),
        ...(params.concurrency === undefined ? {} : { concurrency: params.concurrency }),
        ...(params.max_agent_calls === undefined ? {} : { maxAgentCalls: params.max_agent_calls }),
        modelProfile: params.model_profile ?? ''
      }
      const response = await opts.rpc(rpcMethods.workflowCreate, request, { turn: opts.turnStart.turn })

      return jsonToolResult({
        run_id: modelIntegerIDFromWire(response.runId, 'Workflow run id'),
        status: WorkflowStatusSchema.parse(response.status)
      })
    }
  })
}

function workflowParamsSchema(customModelProfiles: CustomModelProfile[]): z.ZodType<WorkflowParams> {
  const base = z
    .object({
      title: z
        .string()
        .min(1)
        .max(200)
        .refine(value => value.trim().length > 0, 'title must not be blank'),
      script: z
        .string()
        .min(1)
        .refine(value => value.trim().length > 0, 'script must not be blank')
        .refine(value => utf8ByteLength(value) <= WORKFLOW_SCRIPT_MAX_BYTES, 'script exceeds the 256 KiB limit'),
      args: z
        .record(z.string(), z.unknown())
        .refine(
          value => utf8ByteLength(JSON.stringify(value)) <= WORKFLOW_ARGS_MAX_BYTES,
          'args exceeds the 64 KiB limit'
        )
        .optional(),
      concurrency: z.number().int().min(1).max(32).optional(),
      max_agent_calls: z.number().int().min(1).max(1_024).optional()
    })
    .strict()

  if (customModelProfiles.length === 0) return base
  return base.extend({ model_profile: customModelProfileSchema(customModelProfiles).optional() }).strict()
}
