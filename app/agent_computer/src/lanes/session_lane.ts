import { create } from '@bufbuild/protobuf'
import type { AgentConversationContextResponse } from './rpc_lane'
import {
  SessionKeySchema,
  RunRefSchema,
  JobTurnRefSchema,
  fetchRuntimeConfigFromProto,
  jsonObjectFromBytes,
  safeNumberFromBigInt,
  type SignalEnvelopeMessage,
  type Envelope,
  type RenderedFetchRuntimeConfig,
  type TurnModelRefMessage
} from '../fabric/envelope_proto'
import type {
  RunRef as RunRefMessage,
  JobTurnRef as JobTurnRefMessage
} from '../fabric/generated/ankole/runtime_fabric/v1/envelope_pb'
import type { JsonObject as JSONObject } from '@agentbull/active-support'
import { HostedTool } from '../fabric/generated/ankole/runtime_fabric/v1/envelope_pb'

export type RunRef = { session: { session_id: string }; signal_id: string }
export type JobTurnRef = RunRef & { job_id: number; attempt: number }

export function runRefToProto(run: RunRef): RunRefMessage {
  return create(RunRefSchema, {
    session: create(SessionKeySchema, { sessionId: run.session.session_id }),
    signalId: run.signal_id
  })
}
export function runRefFromProto(run: RunRefMessage | undefined): RunRef {
  if (!run?.session) throw new Error('run.session is required')
  return {
    session: {
      session_id: requiredString(run.session.sessionId, 'run.session.session_id')
    },
    signal_id: requiredString(run.signalId, 'run.signal_id')
  }
}
export function jobTurnRefToProto(run: JobTurnRef): JobTurnRefMessage {
  return create(JobTurnRefSchema, {
    signalId: run.signal_id,
    jobId: BigInt(run.job_id),
    attempt: run.attempt
  })
}

/** One worker execution handles exactly one signal_id. */
export type SignalEnvelope = {
  signal_id: string
  type: string
  binding_name?: string
  payload_json?: JSONObject
}

export type TurnStart = {
  fetch_runtime_config: RenderedFetchRuntimeConfig
  mode: 'start' | 'adopt'
  agent_context?: AgentConversationContextResponse
  turn: JobTurnRef
  signal: SignalEnvelope
  model_ref?: TurnModelRef | null
  hosted_tools?: HostedTool[]
  request_context?: JSONObject
  runtime_env?: Record<string, string>
}

export type TurnSteerUpdate = { signal?: SignalEnvelope }

export type MailboxUpdated = {
  turn?: JobTurnRef
  signal: SignalEnvelope
}

export type TurnControl = {
  turn?: JobTurnRef
  command?: string
  payload_json?: JSONObject
}

export type TurnModelRef = {
  provider_id: string
  model: string
  provider_kind?: string
  provider_options?: JSONObject
  supports_parallel_tool_calls?: boolean
  context_length?: number
  input_modalities?: string[]
  vision_fallback_model_ref?: TurnModelRef | null
}

export function turnStartFromEnvelope(envelope: Envelope): TurnStart {
  if (envelope.body.case !== 'turnStart') {
    throw new Error(`expected turn_start envelope, got ${envelope.body.case}`)
  }

  const turnStart = envelope.body.value
  if (!turnStart.signal) {
    throw new Error('turn_start.signal is required')
  }

  if (turnStart.mode !== 'start' && turnStart.mode !== 'adopt') throw new Error('invalid turn_start.mode')
  return {
    mode: turnStart.mode,
    agent_context: turnStart.agentContext,
    turn: jobTurnRefFromProto(turnStart.turn, 'turn_start.turn'),
    signal: signalFromProto(turnStart.signal),
    fetch_runtime_config: fetchRuntimeConfigFromProto(turnStart.fetchRuntimeConfig, 'turn_start.fetch_runtime_config'),
    model_ref: turnStart.modelRef ? turnModelRefFromProto(turnStart.modelRef) : undefined,
    request_context: jsonObjectFromBytes(turnStart.requestContextJson, 'turn_start.request_context_json'),
    runtime_env: { ...turnStart.runtimeEnv },
    hosted_tools: [...turnStart.hostedTools]
  }
}

/**
 * The update may omit `turn` when it is only a projection notification; active
 * steering requires a turn fence so the worker can route it to one in-flight
 * execution.
 */
export function mailboxUpdatedFromEnvelope(envelope: Envelope): MailboxUpdated {
  if (envelope.body.case !== 'mailboxUpdated') {
    throw new Error(`expected mailbox_updated envelope, got ${envelope.body.case}`)
  }

  const mailboxUpdated = envelope.body.value
  if (!mailboxUpdated.signal) {
    throw new Error('mailbox_updated.signal is required')
  }

  return {
    ...(mailboxUpdated.turn ? { turn: jobTurnRefFromProto(mailboxUpdated.turn, 'mailbox_updated.turn') } : {}),
    signal: signalFromProto(mailboxUpdated.signal)
  }
}

export function turnControlFromEnvelope(envelope: Envelope): TurnControl {
  if (envelope.body.case !== 'turnControl') {
    throw new Error(`expected turn_control envelope, got ${envelope.body.case}`)
  }

  const turnControl = envelope.body.value

  return {
    ...(turnControl.turn ? { turn: jobTurnRefFromProto(turnControl.turn, 'turn_control.turn') } : {}),
    ...(turnControl.command ? { command: turnControl.command } : {}),
    payload_json: jsonObjectFromBytes(turnControl.payloadJson, 'turn_control.payload_json')
  }
}

export function jobTurnRefFromProto(turn: JobTurnRefMessage | undefined, path: string): JobTurnRef {
  if (!turn) throw new Error(`${path} is required`)
  const jobID = safeNumberFromBigInt(turn.jobId, `${path}.job_id`)
  if (jobID <= 0 || turn.attempt <= 0) throw new Error(`${path} is not a current Job attempt reference`)
  return {
    session: { session_id: `job:${jobID}` },
    signal_id: requiredString(turn.signalId, `${path}.signal_id`),
    job_id: jobID,
    attempt: turn.attempt
  }
}

function signalFromProto(event: SignalEnvelopeMessage): SignalEnvelope {
  return {
    signal_id: event.signalId,
    type: event.type,
    ...(event.bindingName ? { binding_name: event.bindingName } : {}),
    payload_json: jsonObjectFromBytes(event.payloadJson, 'signal.payload_json')
  }
}

function turnModelRefFromProto(modelRef: TurnModelRefMessage): TurnModelRef {
  return {
    provider_id: modelRef.providerId,
    model: modelRef.model,
    ...(modelRef.providerKind ? { provider_kind: modelRef.providerKind } : {}),
    provider_options:
      jsonObjectFromBytes(modelRef.providerOptionsJson, 'turn_start.model_ref.provider_options_json') ?? {},
    supports_parallel_tool_calls: modelRef.supportsParallelToolCalls,
    ...(modelRef.contextLength !== undefined ? { context_length: modelRef.contextLength } : {}),
    ...(modelRef.inputModalities.length > 0 ? { input_modalities: modelRef.inputModalities } : {}),
    ...(modelRef.visionFallbackModelRef
      ? { vision_fallback_model_ref: turnModelRefFromProto(modelRef.visionFallbackModelRef) }
      : {})
  }
}

function requiredString(value: string, path: string): string {
  if (value.trim() === '') {
    throw new Error(`${path} is required`)
  }
  return value
}
