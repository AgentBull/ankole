import { create } from '@bufbuild/protobuf'
import { jsonObject, type JsonObject as JSONObject } from '@agentbull/active-support'
import { jsonFromBytes } from '../../src/fabric/envelope_proto'
import { BackgroundAgentJobTurnUpsertResponseSchema } from '../../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import type { ActorTurnRef } from '../../src/lanes/actor_lane'
import type { RPCRequestInit } from '../../src/lanes/rpc_lane'
import type { ThreadItem } from '../../src/core/codex-runner/generated/protocol/v2/ThreadItem'
import { BackgroundAgentJobTurnRecorder } from '../../src/core/codex-runner/job/turn-recorder'
import type { WorkerTurnTrace } from '../../src/observability/turn-tracing'

/**
 * Decoded snake_case view of one recorded upsert so assertions read the JSON
 * documents directly.
 */
export type DecodedUpsert = {
  job_id?: string
  attempt?: number
  runtime_thread_id?: string
  runtime_turn_id?: string
  kind?: string
  status?: string
  revision?: number
  trajectory: JSONObject
  turn_items: Array<JSONObject & { position: number; item_key: string; item: JSONObject }>
  progress: JSONObject
  usage?: JSONObject
  error: JSONObject
  started_at?: string
  completed_at?: string
}

type CollabAgentToolItem = Extract<ThreadItem, { type: 'collabAgentToolCall' }>

export function decodedUpsert(request: RPCRequestInit<'background_agent_job.turn.upsert'>): DecodedUpsert {
  const doc = (bytes: Uint8Array | undefined) => (bytes?.length ? (jsonFromBytes(bytes) as JSONObject) : undefined)
  const usage = doc(request.usageJson)
  return {
    job_id: request.jobId,
    attempt: request.attempt,
    runtime_thread_id: request.runtimeThreadId,
    runtime_turn_id: request.runtimeTurnId,
    kind: request.kind,
    status: request.status,
    revision: request.revision,
    trajectory: doc(request.trajectoryJson) ?? {},
    turn_items: (doc(request.turnItemsJson) ?? []) as unknown as Array<
      JSONObject & { position: number; item_key: string; item: JSONObject }
    >,
    progress: doc(request.progressJson) ?? {},
    ...(usage ? { usage } : {}),
    error: doc(request.errorJson) ?? {},
    started_at: request.startedAt,
    ...(request.completedAt ? { completed_at: request.completedAt } : {})
  }
}

export const actorTurn: ActorTurnRef = {
  actor: { agent_uid: 'agent-1', session_id: 'job:1000' },
  activation_uid: 'activation-1',
  actor_epoch: 1,
  actor_event_id: 'event-1',
  revision: 0
}

export function fixture(delayMs = 5, turnTrace?: WorkerTurnTrace) {
  const upserts: DecodedUpsert[] = []
  const recorder = new BackgroundAgentJobTurnRecorder({
    jobID: '1000',
    attempt: 1,
    actorTurn,
    turnTrace,
    checkpointDelayMs: delayMs,
    upsert: async request => {
      upserts.push(decodedUpsert(request))
      return create(BackgroundAgentJobTurnUpsertResponseSchema, {
        jobId: request.jobId,
        turn: {
          id: `stored:${request.runtimeTurnId}`,
          attempt: request.attempt,
          runtimeThreadId: request.runtimeThreadId,
          runtimeTurnId: request.runtimeTurnId,
          kind: request.kind,
          status: request.status,
          revision: request.revision,
          trajectoryJson: request.trajectoryJson,
          progressJson: request.progressJson,
          usageJson: request.usageJson,
          errorJson: request.errorJson,
          startedAt: request.startedAt,
          completedAt: request.completedAt ?? ''
        }
      })
    }
  })
  return { recorder, upserts }
}

export function turnItems(upserts: DecodedUpsert[]) {
  return upserts.flatMap(request => request.turn_items)
}

export function startedTurn() {
  return jsonObject({
    id: 'turn-1',
    status: 'inProgress',
    itemsView: 'full',
    items: [],
    error: null,
    startedAt: Date.now() / 1_000,
    completedAt: null,
    durationMs: null
  })
}

export function notification(method: string, params: Record<string, unknown>) {
  return {
    method,
    params: {
      threadId: 'thread-1',
      turnId: 'turn-1',
      ...params
    }
  }
}

export function commandItem(id: string, command: string, aggregatedOutput: string, status: string) {
  return {
    type: 'commandExecution',
    id,
    command,
    cwd: '/agents/agent-1/jobs/job-1',
    processId: null,
    source: 'unifiedExec',
    status,
    commandActions: [],
    aggregatedOutput,
    exitCode: status === 'completed' ? 0 : null,
    durationMs: status === 'completed' ? 1 : null
  }
}

export function collabItem(
  id: string,
  tool: 'spawnAgent' | 'sendInput' | 'resumeAgent' | 'wait' | 'closeAgent',
  overrides: Partial<CollabAgentToolItem>
): CollabAgentToolItem {
  return {
    type: 'collabAgentToolCall',
    id,
    tool,
    status: 'completed',
    senderThreadId: 'thread-1',
    receiverThreadIds: [],
    prompt: null,
    model: null,
    reasoningEffort: null,
    agentsStates: {},
    ...overrides
  }
}
