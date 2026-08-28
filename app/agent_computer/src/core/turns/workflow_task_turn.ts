import { isRecord } from '@agentbull/active-support'
import type { TurnStart, TurnHostedTool } from '../../lanes/actor_lane'
import { brainRPCRequester, type AgentConversationContextResponse } from '../../lanes/rpc_lane'
import { workerTurnTrace } from '../../observability/turn-tracing'
import { createCreateBackgroundJobTool } from '../../tools/background-agent-job/create-background-job'
import { createSendMessageToBackgroundJobTool } from '../../tools/background-agent-job/send-message-to-background-job'
import { createShowBackgroundJobDetailsTool } from '../../tools/background-agent-job/show-background-job-details'
import { createStopBackgroundJobTool } from '../../tools/background-agent-job/stop-background-job'
import { createBrainJobTools } from '../../tools/brain/brain-tools'
import { createWorkflowSleepTool } from '../../tools/workflow/sleep'
import { createWorkflowSubmitResultTool, submitWorkflowTaskFailure } from '../../tools/workflow/submit-result'
import { runAgentLoop } from '../agent-loop'
import { assistantText, userMessage } from '../llm'
import type { WorkerAgentTool } from '../types'
import { actorEventText } from './actor_event_text'
import { resolveAgentWorkerEnvParts } from '../execution/worker_env'
import { resolveBrainEnabled } from './brain_context'
import { createTurnActivity } from './turn_activity'
import { acquireTurnAIGatewayAccess } from './turn_ai_gateway_access'
import { resolveAgentConversationContext } from './turn_context'
import { resolveRenderedFetchRuntimeConfig } from './rendered_fetch_runtime_config'
import {
  agentRuntimePolicyFromTurnStart,
  statefulTruncationFromActorEventPayload,
  webSearchIsProviderHosted
} from './turn_runtime_policy'
import type { TurnHandlerOptions, TurnHandlerResult } from './turn_options'
import { createTurnWebTools } from './turn_web_tools'

type WorkflowTaskContract = {
  runId: string
  callId: string
  prompt: string
  label?: string
  schema: Record<string, unknown>
  /** True when this turn continues a task woken from `sleeping`. */
  wakeTurn: boolean
}

/** Runs one isolated subagent task with a fixed, non-recursive tool catalog. */
export async function runWorkflowTaskTurn(turnStart: TurnStart, opts: TurnHandlerOptions): Promise<TurnHandlerResult> {
  const task = workflowTaskContractFromTurnStart(turnStart)
  const runtimePolicy = agentRuntimePolicyFromTurnStart(turnStart)
  const turnActivity = createTurnActivity({
    sourceSignal: opts.abortSignal,
    inactivityTimeoutMs: runtimePolicy.inactivityTimeoutMs
  })
  const requeueController = new AbortController()
  const turnSignal = AbortSignal.any([turnActivity.signal, requeueController.signal])

  try {
    const { model, aiGateway, visionFallbackModel } = await acquireTurnAIGatewayAccess(turnStart, {
      requestAIGatewayAPIKey: opts.requestAIGatewayAPIKey,
      runStep: turnActivity.runStep
    })
    const agentContext = await turnActivity.runStep(
      resolveAgentConversationContext(turnStart, opts),
      'agent conversation context'
    )
    const conversationID = agentContext.conversation?.id
    if (!conversationID) throw new Error('Workflow task is missing its AIGateway conversation id.')

    const [renderedFetchRuntimeConfig, brainEnabled, workerEnv] = await Promise.all([
      turnActivity.runStep(resolveRenderedFetchRuntimeConfig(turnStart, opts.rpc), 'rendered fetch runtime config'),
      turnActivity.runStep(resolveBrainEnabled(turnStart, opts.rpc, opts.logger), 'brain runtime config'),
      turnActivity.runStep(
        resolveAgentWorkerEnvParts(turnStart.turn.actor.agent_uid, opts.rpc, turnStart.actor_event.binding_name),
        'worker environment'
      )
    ])
    const webTools = await turnActivity.runStep(
      createTurnWebTools({
        aiGateway,
        renderedFetchRuntimeConfig,
        workerEnv: workerEnv.vars,
        workspaceRoot: opts.workspaceRoot,
        browserRuntime: opts.browserRuntime
      }),
      'web tools'
    )
    let terminalSubmission = false
    let sleeping = false
    const submitResult = createWorkflowSubmitResultTool({
      callId: task.callId,
      resultSchema: task.schema,
      rpc: opts.rpc,
      turn: turnStart.turn,
      onTerminal: () => {
        terminalSubmission = true
      },
      onRequeued: error => requeueController.abort(error)
    })
    const sleep = createWorkflowSleepTool({
      callId: task.callId,
      rpc: opts.rpc,
      turn: turnStart.turn,
      onSleeping: () => {
        sleeping = true
      }
    })
    const brainTools = brainEnabled
      ? createBrainJobTools({ requestBrainRPC: brainRPCRequester(opts.rpc, turnStart.turn) })
      : []
    const tools = workflowTaskTools(turnStart, agentContext, webTools, brainTools, submitResult, sleep, opts)
    const hostedTools = workflowTaskHostedTools(turnStart)

    opts.logger?.info('worker.workflow_task_tools_resolved', 'Workflow task tools resolved.', {
      actor_event_id: turnStart.turn.actor_event_id,
      tool_names: tools.map(tool => tool.name),
      hosted_tool_types: hostedTools.map(tool => tool.type)
    })

    let proseReturned = false
    const latest = await runAgentLoop({
      model,
      turnTrace: workerTurnTrace(turnStart),
      systemPrompt: workflowTaskSystemPrompt(turnStart, task, agentContext),
      messages: [userMessage(workflowTaskTurnInputText(turnStart, task))],
      modelInputModalities: turnStart.model_ref?.input_modalities,
      visionFallbackModel,
      maxTokens: runtimePolicy.maxOutputTokens,
      maxModelIterations: runtimePolicy.maxIterations,
      stateful: {
        actorEventID: turnStart.actor_event.actor_event_id,
        conversationID,
        truncation: statefulTruncationFromActorEventPayload(turnStart.actor_event.payload_json)
      },
      tools,
      hostedTools,
      repairTools: [submitResult, sleep],
      repairHostedTools: [],
      nudgeEmptyAfterTools: false,
      abortSignal: turnSignal,
      onActivity: turnActivity.touch,
      logger: opts.logger,
      onPresentationEvent: opts.onPresentationEvent,
      withActivitySuspended: turnActivity.withSuspended,
      repairFinalResponse: message => {
        if (terminalSubmission || sleeping) return undefined
        if (assistantText(message) !== '') proseReturned = true
        return userMessage(
          'You did not end this Workflow task turn. Call submit_result with the final result, or call sleep when you wait for a delegated job or a later condition. Do not call another tool and do not return prose.'
        )
      }
    })

    if (sleeping) return { kind: 'noop_completed', reason: 'workflow_task_sleeping' }
    if (terminalSubmission) return { kind: 'noop_completed', reason: 'workflow_task_committed' }

    const finalText = assistantText(latest.message)
    const failure = missingWorkflowTaskSubmissionFailure(proseReturned, finalText)
    await submitWorkflowTaskFailure({ callId: task.callId, rpc: opts.rpc, turn: turnStart.turn }, failure)
    return { kind: 'noop_completed', reason: 'workflow_task_committed' }
  } finally {
    turnActivity.cleanup()
  }
}

function workflowTaskContractFromTurnStart(turnStart: TurnStart): WorkflowTaskContract {
  const wakeTurn = turnStart.actor_event.type !== 'workflow.task.dispatch'
  const data = turnStart.request_context
  if (!isRecord(data)) throw new Error('Workflow task data is required.')

  const runId = positiveModelInteger(data.run_id, 'run_id')
  const callId = positiveModelInteger(data.call_id, 'call_id')
  if (turnStart.turn.actor.session_id !== `wf_task:${callId}`) {
    throw new Error('Workflow task call id does not match its actor session.')
  }
  const prompt = data.prompt
  if (typeof prompt !== 'string' || prompt.trim() === '') {
    throw new Error('Workflow task prompt is required.')
  }
  const label = typeof data.label === 'string' && data.label.trim() !== '' ? data.label.trim() : undefined
  const schema = data.schema === undefined || data.schema === null ? { type: 'string' } : data.schema
  if (!isRecord(schema)) throw new Error('Workflow task result schema must be an object.')

  return { runId, callId, prompt, ...(label ? { label } : {}), schema, wakeTurn }
}

function workflowTaskTurnInputText(turnStart: TurnStart, task: WorkflowTaskContract): string {
  if (!task.wakeTurn) return task.prompt
  return actorEventText(turnStart.actor_event.payload_json, turnStart.actor_event.type)
}

function workflowTaskTools(
  turnStart: TurnStart,
  agentContext: AgentConversationContextResponse,
  webTools: WorkerAgentTool[],
  brainTools: WorkerAgentTool[],
  submitResult: WorkerAgentTool,
  sleep: WorkerAgentTool,
  opts: TurnHandlerOptions
): WorkerAgentTool[] {
  const providerHostedWebSearch = webSearchIsProviderHosted(turnStart)
  return [
    ...webTools.filter(tool => !providerHostedWebSearch || tool.name !== 'web_search'),
    ...brainTools.filter(tool => tool.name === 'recall' || tool.name === 'get_page'),
    createCreateBackgroundJobTool({
      turnStart,
      agentPluginCatalog: agentContext.agentPlugins ?? [],
      rpc: opts.rpc
    }),
    createShowBackgroundJobDetailsTool({ turnStart, rpc: opts.rpc }),
    createSendMessageToBackgroundJobTool({ turnStart, rpc: opts.rpc }),
    createStopBackgroundJobTool({ turnStart, rpc: opts.rpc }),
    sleep,
    submitResult
  ]
}

function workflowTaskHostedTools(turnStart: TurnStart): TurnHostedTool[] {
  return (turnStart.hosted_tools ?? []).filter(
    (tool): tool is Extract<TurnHostedTool, { type: 'web_search' }> => tool.type === 'web_search'
  )
}

function workflowTaskSystemPrompt(
  turnStart: TurnStart,
  task: WorkflowTaskContract,
  context: AgentConversationContextResponse
): string {
  const displayName = context.agent?.displayName?.trim() || turnStart.turn.actor.agent_uid
  const identity = [context.soul.trim(), context.mission.trim()].filter(Boolean).join('\n\n')
  return [
    `You are ${displayName}, an Ankole Agent executing one isolated Workflow task.`,
    identity,
    '<workflow_task_contract>',
    `Run id: ${task.runId}`,
    `Call id: ${task.callId}`,
    ...(task.label ? [`Task label: ${JSON.stringify(task.label)}`] : []),
    'Complete the task, then call submit_result as your final action.',
    'Call submit_result exactly once unless it rejects the result schema. If it rejects the result, correct the value and call it again.',
    'Do not return the task result as prose.',
    'You can delegate long work with create_background_job, then call sleep to hibernate until a job lifecycle event, a main-Agent message, or your deadline wakes this task in the same conversation.',
    'Do not call submit_result while a job you created is still live: wait for its event and read its result, or stop_background_job first.',
    'A delegated job cannot ask a human. If you cannot proceed without main-Agent input, sleep with attention set to true and a note that states the needed decision.',
    `The result must match this JSON Schema: ${JSON.stringify(task.schema)}`,
    '</workflow_task_contract>',
    ...(task.wakeTurn
      ? [
          'This turn continues your earlier work: you slept and an event woke you. Read the event, use your conversation context, and end the turn with submit_result or another sleep.'
        ]
      : [])
  ]
    .filter(Boolean)
    .join('\n\n')
}

function missingWorkflowTaskSubmissionFailure(
  proseReturned: boolean,
  finalText: string
): { code: string; summary: string; retryable: boolean } {
  if (!proseReturned && finalText.trim() === '') {
    return {
      code: 'empty_output',
      summary: 'Workflow task returned no result and did not call submit_result.',
      retryable: true
    }
  }
  return {
    code: 'schema_noncompliance',
    summary: 'Workflow task returned prose instead of a schema-valid submit_result value.',
    retryable: false
  }
}

function positiveModelInteger(value: unknown, field: string): string {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`Workflow task ${field} must be a positive model-safe integer.`)
  }
  return String(value)
}
