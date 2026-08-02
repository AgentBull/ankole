import { create } from '@bufbuild/protobuf'
import { isRecord } from '@agentbull/active-support'
import {
  ActorKeySchema,
  ActorTurnRefSchema,
  jsonObjectFromBytes,
  safeNumberFromBigInt,
  type ActorEventEnvelopeMessage,
  type ActorTurnRefMessage,
  type Envelope,
  type TurnModelRefMessage
} from '../fabric/envelope_proto'
import type { JsonObject as JSONObject } from '@agentbull/active-support'

/**
 * Durable turn fence echoed by every worker reply.
 *
 * The control plane compares these fields with database rows before accepting
 * durable output, which makes late replies from old workers harmless. This
 * snake_case DTO is also the fence shape carried inside RPC `payload_json`
 * contracts, so it stays a plain JSON object; the generated envelope message
 * exists only at the fabric codec boundary.
 */
export type ActorTurnRef = {
  actor: {
    agent_uid: string
    session_id: string
  }
  activation_uid: string
  actor_epoch: number
  actor_event_id: string
  revision: number
}

/**
 * Actor event payload delivered to the computer worker.
 *
 * One worker execution handles exactly one actor_event_id.
 */
export type ActorEventEnvelope = {
  actor_event_id: string
  queue_sequence: number
  type: string
  source_event_id: string
  binding_name?: string
  signal_channel_id?: string
  provider_thread_id?: string
  source_entry_id?: string
  payload_json?: JSONObject
}

export type TurnStart = {
  turn: ActorTurnRef
  actor_event: ActorEventEnvelope
  workspace_id: number
  model_ref?: TurnModelRef | null
  hosted_tools?: TurnHostedTool[]
  request_context?: JSONObject
  runtime_env?: Record<string, string>
}

export type TurnHostedTool = { type: 'image_generation' }

export type TurnSteerUpdate = {
  turn: ActorTurnRef
  actorEvent?: ActorEventEnvelope
  correlationID?: string
}

export type MailboxUpdated = {
  turn?: ActorTurnRef
  actor_event: ActorEventEnvelope
  reason?: string
}

export type TurnControl = {
  turn?: ActorTurnRef
  command?: string
  payload_json?: JSONObject
}

export type TurnModelRef = {
  profile: string
  provider_id: string
  model: string
  provider_kind?: string
  provider_options?: JSONObject
  supports_parallel_tool_calls?: boolean
  context_length?: number
  input_modalities?: string[]
  max_completion_tokens?: number
  vision_fallback_model_ref?: TurnModelRef | null
}

/**
 * Extracts a turn-start payload and fails fast on wrong envelope types.
 */
export function turnStartFromEnvelope(envelope: Envelope): TurnStart {
  if (envelope.body.case !== 'turnStart') {
    throw new Error(`expected turn_start envelope, got ${envelope.body.case}`)
  }

  const turnStart = envelope.body.value
  if (!turnStart.actorEvent) {
    throw new Error('turn_start.actor_event is required')
  }

  const hostedTools = turnHostedToolsFromBytes(turnStart.hostedToolsJson)
  const workspaceID = safeNumberFromBigInt(turnStart.workspaceId, 'turn_start.workspace_id')
  if (workspaceID < 10_000) {
    throw new Error('turn_start.workspace_id must be a model-safe integer starting at 10000')
  }

  return {
    turn: actorTurnRefFromProto(turnStart.turn, 'turn_start.turn'),
    actor_event: actorEventFromProto(turnStart.actorEvent),
    workspace_id: workspaceID,
    model_ref: turnStart.modelRef ? turnModelRefFromProto(turnStart.modelRef) : undefined,
    request_context: jsonObjectFromBytes(turnStart.requestContextJson, 'turn_start.request_context_json'),
    runtime_env: { ...turnStart.runtimeEnv },
    ...(hostedTools ? { hosted_tools: hostedTools } : {})
  }
}

/**
 * Extracts a mailbox update carrying a journaled actor event.
 *
 * The update may omit `turn` when it is only a projection notification; active
 * steering requires a turn fence so the worker can route it to one in-flight
 * execution.
 */
export function mailboxUpdatedFromEnvelope(envelope: Envelope): MailboxUpdated {
  if (envelope.body.case !== 'mailboxUpdated') {
    throw new Error(`expected mailbox_updated envelope, got ${envelope.body.case}`)
  }

  const mailboxUpdated = envelope.body.value
  if (!mailboxUpdated.actorEvent) {
    throw new Error('mailbox_updated.actor_event is required')
  }

  return {
    ...(mailboxUpdated.turn ? { turn: actorTurnRefFromProto(mailboxUpdated.turn, 'mailbox_updated.turn') } : {}),
    actor_event: actorEventFromProto(mailboxUpdated.actorEvent),
    ...(mailboxUpdated.reason ? { reason: mailboxUpdated.reason } : {})
  }
}

/**
 * Extracts a control command for an active turn.
 */
export function turnControlFromEnvelope(envelope: Envelope): TurnControl {
  if (envelope.body.case !== 'turnControl') {
    throw new Error(`expected turn_control envelope, got ${envelope.body.case}`)
  }

  const turnControl = envelope.body.value

  return {
    ...(turnControl.turn ? { turn: actorTurnRefFromProto(turnControl.turn, 'turn_control.turn') } : {}),
    ...(turnControl.command ? { command: turnControl.command } : {}),
    payload_json: jsonObjectFromBytes(turnControl.payloadJson, 'turn_control.payload_json')
  }
}

/**
 * Converts the domain turn fence into the generated envelope message.
 */
export function actorTurnRefToProto(turn: ActorTurnRef): ActorTurnRefMessage {
  return create(ActorTurnRefSchema, {
    actor: create(ActorKeySchema, {
      agentUid: turn.actor.agent_uid,
      sessionId: turn.actor.session_id
    }),
    activationUid: turn.activation_uid,
    actorEpoch: BigInt(turn.actor_epoch),
    actorEventId: turn.actor_event_id,
    revision: turn.revision
  })
}

/**
 * Converts the generated turn fence into the domain DTO the runtime and RPC
 * payload contracts use, checking the 64-bit epoch stays a safe JSON number.
 */
export function actorTurnRefFromProto(turn: ActorTurnRefMessage | undefined, path: string): ActorTurnRef {
  if (!turn?.actor) {
    throw new Error(`${path} is required`)
  }

  return {
    actor: {
      agent_uid: requiredString(turn.actor.agentUid, `${path}.actor.agent_uid`),
      session_id: requiredString(turn.actor.sessionId, `${path}.actor.session_id`)
    },
    activation_uid: requiredString(turn.activationUid, `${path}.activation_uid`),
    actor_epoch: safeNumberFromBigInt(turn.actorEpoch, `${path}.actor_epoch`),
    actor_event_id: requiredString(turn.actorEventId, `${path}.actor_event_id`),
    revision: turn.revision
  }
}

function actorEventFromProto(event: ActorEventEnvelopeMessage): ActorEventEnvelope {
  return {
    actor_event_id: event.actorEventId,
    queue_sequence: safeNumberFromBigInt(event.queueSequence, 'actor_event.queue_sequence'),
    type: event.type,
    source_event_id: event.sourceEventId,
    ...(event.bindingName ? { binding_name: event.bindingName } : {}),
    ...(event.signalChannelId ? { signal_channel_id: event.signalChannelId } : {}),
    ...(event.providerThreadId ? { provider_thread_id: event.providerThreadId } : {}),
    ...(event.sourceEntryId ? { source_entry_id: event.sourceEntryId } : {}),
    payload_json: jsonObjectFromBytes(event.payloadJson, 'actor_event.payload_json')
  }
}

function turnModelRefFromProto(modelRef: TurnModelRefMessage): TurnModelRef {
  return {
    profile: modelRef.profile,
    provider_id: modelRef.providerId,
    model: modelRef.model,
    ...(modelRef.providerKind ? { provider_kind: modelRef.providerKind } : {}),
    provider_options:
      jsonObjectFromBytes(modelRef.providerOptionsJson, 'turn_start.model_ref.provider_options_json') ?? {},
    supports_parallel_tool_calls: modelRef.supportsParallelToolCalls,
    ...(modelRef.contextLength !== undefined ? { context_length: modelRef.contextLength } : {}),
    ...(modelRef.inputModalities.length > 0 ? { input_modalities: modelRef.inputModalities } : {}),
    ...(modelRef.maxCompletionTokens !== undefined ? { max_completion_tokens: modelRef.maxCompletionTokens } : {}),
    ...(modelRef.visionFallbackModelRef
      ? { vision_fallback_model_ref: turnModelRefFromProto(modelRef.visionFallbackModelRef) }
      : {})
  }
}

/**
 * Reads a required non-empty string from the decoded envelope.
 */
function requiredString(value: string, path: string): string {
  if (value.trim() === '') {
    throw new Error(`${path} is required`)
  }
  return value
}

function turnHostedToolsFromBytes(bytes: Uint8Array): TurnHostedTool[] | undefined {
  if (bytes.length === 0) return undefined
  const value = JSON.parse(new TextDecoder().decode(bytes)) as unknown
  if (!Array.isArray(value)) throw new Error('turn_start.hosted_tools must be an array')

  return value.map((tool, index) => {
    if (!isRecord(tool) || tool.type !== 'image_generation' || Object.keys(tool).length !== 1) {
      throw new Error(`turn_start.hosted_tools[${index}] must declare only image_generation`)
    }
    return { type: 'image_generation' }
  })
}
