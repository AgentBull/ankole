import { create, fromBinary, toBinary } from '@bufbuild/protobuf'

export { create } from '@bufbuild/protobuf'
import {
  EnvelopeSchema,
  type ActorEventEnvelope as ActorEventEnvelopeMessage,
  type ActorTurnRef as ActorTurnRefMessage,
  type Envelope,
  type TurnModelRef as TurnModelRefMessage
} from './generated/ankole/runtime_fabric/v1/envelope_pb'
import type { JsonObject as JSONObject } from '@agentbull/active-support'
import { Buffer } from 'node:buffer'

type JSONValue = string | number | boolean | null | JSONValue[] | JSONObject

/**
 * Canonical local names for the envelope codec generated from `envelope.proto`.
 *
 * The generated module keeps the upstream protoc-gen-es naming policy
 * (camelCase fields, bigint 64-bit integers). Turn-lane consumers import
 * through this module and convert to the snake_case domain DTOs at the lane
 * boundary. RPC business payloads are the generated `rpc.proto` messages
 * themselves, accessed through the `rpc_lane` registry without a DTO layer.
 */
export {
  ControlShutdownSchema,
  DurabilityClass,
  EnvelopeSchema,
  Lane,
  MailboxUpdatedSchema,
  RPCErrorSchema,
  RPCRequestSchema,
  RPCResponseSchema,
  TurnAcceptedSchema,
  TurnCompletedSchema,
  TurnCompletionOutcome,
  TurnControlSchema,
  TurnErrorSchema,
  TurnNoopCompletedSchema,
  TurnStartSchema,
  WorkerProgressSchema,
  AgentComputerWorkerCapacitySchema,
  AgentComputerWorkerHeartbeatSchema,
  AgentComputerWorkerReadySchema,
  ActorEventEnvelopeSchema,
  ActorKeySchema,
  ActorTurnRefSchema,
  TurnModelRefSchema
} from './generated/ankole/runtime_fabric/v1/envelope_pb'
export type { ActorEventEnvelopeMessage, ActorTurnRefMessage, Envelope, TurnModelRefMessage }
export type {
  AgentComputerWorkerCapacity as AgentComputerWorkerCapacityMessage,
  AgentComputerWorkerHeartbeat as AgentComputerWorkerHeartbeatMessage,
  AgentComputerWorkerReady as AgentComputerWorkerReadyMessage,
  ControlShutdown as ControlShutdownMessage,
  MailboxUpdated as MailboxUpdatedMessage,
  RPCError as RPCErrorMessage,
  RPCRequest as RPCRequestMessage,
  RPCResponse as RPCResponseMessage,
  TurnCompleted as TurnCompletedMessage,
  TurnControl as TurnControlMessage,
  TurnError as TurnErrorMessage,
  TurnNoopCompleted as TurnNoopCompletedMessage,
  TurnStart as TurnStartMessage,
  WorkerProgress as WorkerProgressMessage
} from './generated/ankole/runtime_fabric/v1/envelope_pb'

export function encodeEnvelope(envelope: Envelope): Buffer {
  return Buffer.from(toBinary(EnvelopeSchema, envelope))
}

export function decodeEnvelope(bytes: Uint8Array): Envelope {
  return fromBinary(EnvelopeSchema, bytes)
}

/**
 * Builds the shared envelope header; body construction stays with the caller.
 * The kernel seals lane, durability, and protocol version from the body at
 * send time, so the header carries only the ids and the send instant.
 */
export function envelopeHeader(
  messageID: string,
  correlationID?: string
): Pick<Envelope, 'messageId' | 'correlationId' | 'sentAtUnixMs'> {
  return {
    messageId: messageID,
    correlationId: correlationID ?? messageID,
    sentAtUnixMs: BigInt(Date.now())
  }
}

export function createEnvelope(fields: Parameters<typeof create<typeof EnvelopeSchema>>[1]): Envelope {
  return create(EnvelopeSchema, fields)
}

/**
 * Encodes a domain JSON value into a `*_json` bytes field; absent stays empty.
 */
export function jsonBytes(value: JSONValue | undefined): Uint8Array {
  if (value === undefined) return new Uint8Array(0)
  return new TextEncoder().encode(JSON.stringify(value))
}

/**
 * Decodes a `*_json` bytes field. Empty bytes mean "absent"; invalid JSON is a
 * producer bug and throws instead of degrading.
 */
export function jsonFromBytes(bytes: Uint8Array): JSONValue | undefined {
  if (bytes.length === 0) return undefined
  return JSON.parse(new TextDecoder().decode(bytes)) as JSONValue
}

export function jsonObjectFromBytes(bytes: Uint8Array, field: string): JSONObject | undefined {
  const value = jsonFromBytes(bytes)
  if (value === undefined) return undefined
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new Error(`${field} must decode to a JSON object`)
  }
  return value as JSONObject
}

/**
 * Converts a wire bigint into the JSON-number range the domain DTOs use.
 *
 * Domain and RPC payload contracts carry these as JSON numbers, so a value
 * outside the safe-integer range is a protocol violation, not a rounding case.
 */
export function safeNumberFromBigInt(value: bigint, field: string): number {
  const converted = Number(value)
  if (!Number.isSafeInteger(converted)) {
    throw new Error(`${field} exceeds the safe JSON integer range: ${value}`)
  }
  return converted
}
