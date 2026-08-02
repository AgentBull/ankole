import {
  create,
  fromBinary,
  toBinary,
  type DescMessage,
  type MessageInitShape,
  type MessageShape
} from '@bufbuild/protobuf'
import type { JsonObject as JSONObject } from '@agentbull/active-support'
import type { EnvelopeSender } from '../fabric/fabric'
import type { ActorTurnRef } from './actor_lane'
import { actorTurnRefToProto } from './actor_lane'
import {
  createEnvelope,
  DurabilityClass,
  envelopeHeader,
  jsonBytes,
  jsonObjectFromBytes,
  Lane,
  RPCErrorSchema,
  RPCRequestSchema,
  RPCResponseSchema,
  type RPCErrorMessage,
  type RPCRequestMessage,
  type RPCResponseMessage
} from '../fabric/envelope_proto'
import {
  AgentConversationContextRequestSchema,
  AgentConversationContextResponseSchema,
  AgentPluginListRequestSchema,
  AgentPluginListResponseSchema,
  AIGatewayAPIKeyRequestSchema,
  AIGatewayAPIKeyResponseSchema,
  ActorTurnCompleteRequestSchema,
  ActorTurnCompleteResponseSchema,
  AutomationJobCreateRequestSchema,
  AutomationJobEmitRequestSchema,
  AutomationJobEmitResponseSchema,
  AutomationJobListRequestSchema,
  AutomationJobRunRequestSchema,
  AutomationJobRunResponseSchema,
  AutomationJobShowRequestSchema,
  AutomationJobTargetRequestSchema,
  AppConfigureResolveRequestSchema,
  AppConfigureResolveResponseSchema,
  BackgroundAgentJobCreateRequestSchema,
  BackgroundAgentJobGetRequestSchema,
  BackgroundAgentJobListRequestSchema,
  BackgroundAgentJobListResponseSchema,
  BackgroundAgentJobMessageResultRequestSchema,
  BackgroundAgentJobMessageResultResponseSchema,
  BackgroundAgentJobMessageSendRequestSchema,
  BackgroundAgentJobMessageSendResponseSchema,
  BackgroundAgentJobRespawnRequestSchema,
  BackgroundAgentJobRespawnResponseSchema,
  BackgroundAgentJobResponseSchema,
  BackgroundAgentJobStopRequestSchema,
  BackgroundAgentJobStopResponseSchema,
  BackgroundAgentJobStatusUpdateRequestSchema,
  BackgroundAgentJobTurnUpsertRequestSchema,
  BackgroundAgentJobTurnUpsertResponseSchema,
  InstalledSkillReplaceRequestSchema,
  InstalledSkillReplaceResponseSchema,
  JSONPassthroughResponseSchema,
  MemoryBrowseRequestSchema,
  MemoryHealthCheckRequestSchema,
  MemoryOpenRequestSchema,
  MemorySearchRequestSchema,
  MemoryUpdateRequestSchema,
  ScheduleCheckBackLaterCreateRequestSchema,
  ScheduleCheckBackLaterListRequestSchema,
  ScheduleCheckBackLaterTargetRequestSchema,
  ScheduleCheckBackLaterUpdateRequestSchema,
  ScheduleCronAddRequestSchema,
  ScheduleCronListRequestSchema,
  AmbientJudgmentRecordRequestSchema,
  ScheduleCronRunRequestSchema,
  ScheduleCronRunsRequestSchema,
  ScheduleCronTargetRequestSchema,
  ScheduleCronUpdateRequestSchema,
  SignalChannelStandingOrdersSetRequestSchema,
  SkillOverlayAppendRequestSchema,
  SkillOverlayReplaceRequestSchema,
  SkillOverlayResolveRequestSchema,
  SkillOverlayResponseSchema,
  WebhookEndpointCreateRequestSchema,
  WebhookEndpointListRequestSchema,
  WebhookEndpointTargetRequestSchema,
  WorkerEnvResolveRequestSchema,
  WorkerEnvResolveResponseSchema
} from '../fabric/generated/ankole/runtime_fabric/v1/rpc_pb'

/**
 * Worker-originated RuntimeFabric RPC operation registry.
 *
 * `rpcMethods`, `rpcOperationMeta`, and `rpcSchemas` are the Bun side of the
 * cross-language RPC contract. Payload shapes are the generated messages from
 * `app/kernel/proto/ankole/runtime_fabric/v1/rpc.proto`; the Elixir side
 * lives in `Ankole.SignalsGateway.ActorRuntime.RPCLane`; both sides are
 * pinned to the committed `rpc_methods.json` by package-local parity tests.
 * Adding an operation means: messages in `rpc.proto` plus `bun run
 * gen:proto`, one entry in each table here plus `bun run gen:rpc-contract`,
 * and one dispatch row plus one broker function clause on the Elixir side.
 */
export const rpcMethods = {
  aiGatewayAPIKeyForCreateOrFindByAgent: 'ai_gateway.api_key_for.create_or_find_by_agent',
  agentConversationContextResolve: 'agent_conversation.context.resolve',
  actorTurnComplete: 'actor_turn.complete',
  appConfigureResolve: 'app_configure.resolve',
  agentPluginList: 'agent_plugin.list',
  automationJobCreate: 'automation_job.create',
  automationJobList: 'automation_job.list',
  automationJobShow: 'automation_job.show',
  automationJobCancel: 'automation_job.cancel',
  automationJobEmit: 'automation_job.emit',
  automationJobRun: 'automation_job.run',
  backgroundAgentJobCreate: 'background_agent_job.create',
  backgroundAgentJobGet: 'background_agent_job.get',
  backgroundAgentJobList: 'background_agent_job.list',
  backgroundAgentJobMessageSend: 'background_agent_job.message.send',
  backgroundAgentJobMessageResult: 'background_agent_job.message.result',
  backgroundAgentJobRespawn: 'background_agent_job.respawn',
  backgroundAgentJobStop: 'background_agent_job.stop',
  backgroundAgentJobTurnUpsert: 'background_agent_job.turn.upsert',
  backgroundAgentJobStatusUpdate: 'background_agent_job.status.update',
  memorySearch: 'memory_search',
  memoryBrowse: 'memory_browse',
  memoryOpen: 'memory_open',
  memoryUpdate: 'memory_update',
  memoryHealthCheck: 'memory_health_check',
  scheduleCheckBackLaterCreate: 'schedule.check_back_later.create',
  scheduleCheckBackLaterList: 'schedule.check_back_later.list',
  scheduleCheckBackLaterGet: 'schedule.check_back_later.get',
  scheduleCheckBackLaterUpdate: 'schedule.check_back_later.update',
  scheduleCheckBackLaterCancel: 'schedule.check_back_later.cancel',
  scheduleCronList: 'schedule.cron.list',
  scheduleCronGet: 'schedule.cron.get',
  scheduleCronRuns: 'schedule.cron.runs',
  scheduleCronAdd: 'schedule.cron.add',
  scheduleCronUpdate: 'schedule.cron.update',
  scheduleCronPause: 'schedule.cron.pause',
  scheduleCronResume: 'schedule.cron.resume',
  scheduleCronRemove: 'schedule.cron.remove',
  scheduleCronRun: 'schedule.cron.run',
  signalChannelAmbientJudgmentRecord: 'signal_channel.ambient_judgment.record',
  signalChannelStandingOrdersSet: 'signal_channel.standing_orders.set',
  webhookEndpointCreate: 'webhook.endpoint.create',
  webhookEndpointList: 'webhook.endpoint.list',
  webhookEndpointCancel: 'webhook.endpoint.cancel',
  skillsInstalledReplace: 'skills.installed.replace',
  skillsOverlayAppend: 'skills.overlay.append',
  skillsOverlayResolve: 'skills.overlay.resolve',
  skillsOverlayReplace: 'skills.overlay.replace',
  workerEnvResolve: 'worker_env.resolve'
} as const

export type RPCMethod = (typeof rpcMethods)[keyof typeof rpcMethods]

/**
 * Authorization semantics of one operation.
 *
 * `turn` operations carry the turn fence on the RPCRequest frame and are
 * authorized per effect by control-plane `WorkerRouteAuth` before the payload
 * is decoded (write additionally checks the activation revision).
 * `worker_agent` operations carry the trusted subject as the frame
 * `agent_uid` by design.
 */
export type RPCOperationMeta =
  | { scope: 'worker_agent' }
  | { scope: 'turn'; effect: 'read' | 'write' | 'complete' }
  | { owner: 'worker' }

export const rpcOperationMeta = {
  [rpcMethods.aiGatewayAPIKeyForCreateOrFindByAgent]: { scope: 'worker_agent' },
  [rpcMethods.agentConversationContextResolve]: { scope: 'turn', effect: 'read' },
  [rpcMethods.actorTurnComplete]: { scope: 'turn', effect: 'complete' },
  [rpcMethods.appConfigureResolve]: { scope: 'worker_agent' },
  [rpcMethods.agentPluginList]: { scope: 'turn', effect: 'read' },
  [rpcMethods.automationJobCreate]: { scope: 'turn', effect: 'write' },
  [rpcMethods.automationJobList]: { scope: 'turn', effect: 'read' },
  [rpcMethods.automationJobShow]: { scope: 'turn', effect: 'read' },
  [rpcMethods.automationJobCancel]: { scope: 'turn', effect: 'write' },
  [rpcMethods.automationJobEmit]: { scope: 'worker_agent' },
  [rpcMethods.automationJobRun]: { owner: 'worker' },
  [rpcMethods.backgroundAgentJobCreate]: { scope: 'turn', effect: 'write' },
  [rpcMethods.backgroundAgentJobGet]: { scope: 'turn', effect: 'read' },
  [rpcMethods.backgroundAgentJobList]: { scope: 'turn', effect: 'read' },
  [rpcMethods.backgroundAgentJobMessageSend]: { scope: 'turn', effect: 'write' },
  [rpcMethods.backgroundAgentJobMessageResult]: { scope: 'turn', effect: 'read' },
  [rpcMethods.backgroundAgentJobRespawn]: { scope: 'turn', effect: 'write' },
  [rpcMethods.backgroundAgentJobStop]: { scope: 'turn', effect: 'write' },
  [rpcMethods.backgroundAgentJobTurnUpsert]: { scope: 'turn', effect: 'write' },
  [rpcMethods.backgroundAgentJobStatusUpdate]: { scope: 'turn', effect: 'write' },
  [rpcMethods.memorySearch]: { scope: 'turn', effect: 'read' },
  [rpcMethods.memoryBrowse]: { scope: 'turn', effect: 'read' },
  [rpcMethods.memoryOpen]: { scope: 'turn', effect: 'read' },
  [rpcMethods.memoryUpdate]: { scope: 'turn', effect: 'write' },
  [rpcMethods.memoryHealthCheck]: { scope: 'turn', effect: 'read' },
  [rpcMethods.scheduleCheckBackLaterCreate]: { scope: 'turn', effect: 'write' },
  [rpcMethods.scheduleCheckBackLaterList]: { scope: 'turn', effect: 'read' },
  [rpcMethods.scheduleCheckBackLaterGet]: { scope: 'turn', effect: 'read' },
  [rpcMethods.scheduleCheckBackLaterUpdate]: { scope: 'turn', effect: 'write' },
  [rpcMethods.scheduleCheckBackLaterCancel]: { scope: 'turn', effect: 'write' },
  [rpcMethods.scheduleCronList]: { scope: 'turn', effect: 'read' },
  [rpcMethods.scheduleCronGet]: { scope: 'turn', effect: 'read' },
  [rpcMethods.scheduleCronRuns]: { scope: 'turn', effect: 'read' },
  [rpcMethods.scheduleCronAdd]: { scope: 'turn', effect: 'write' },
  [rpcMethods.scheduleCronUpdate]: { scope: 'turn', effect: 'write' },
  [rpcMethods.scheduleCronPause]: { scope: 'turn', effect: 'write' },
  [rpcMethods.scheduleCronResume]: { scope: 'turn', effect: 'write' },
  [rpcMethods.scheduleCronRemove]: { scope: 'turn', effect: 'write' },
  [rpcMethods.scheduleCronRun]: { scope: 'turn', effect: 'write' },
  [rpcMethods.signalChannelAmbientJudgmentRecord]: { scope: 'turn', effect: 'write' },
  [rpcMethods.signalChannelStandingOrdersSet]: { scope: 'turn', effect: 'write' },
  [rpcMethods.webhookEndpointCreate]: { scope: 'turn', effect: 'write' },
  [rpcMethods.webhookEndpointList]: { scope: 'turn', effect: 'read' },
  [rpcMethods.webhookEndpointCancel]: { scope: 'turn', effect: 'write' },
  [rpcMethods.skillsInstalledReplace]: { scope: 'turn', effect: 'write' },
  [rpcMethods.skillsOverlayAppend]: { scope: 'turn', effect: 'write' },
  [rpcMethods.skillsOverlayResolve]: { scope: 'turn', effect: 'read' },
  [rpcMethods.skillsOverlayReplace]: { scope: 'turn', effect: 'write' },
  [rpcMethods.workerEnvResolve]: { scope: 'worker_agent' }
} as const satisfies Record<RPCMethod, RPCOperationMeta>

/**
 * Request and response message schema bound to each operation. Model-facing
 * passthrough families (memory, schedule) share `JSONPassthroughResponse`.
 */
export const rpcSchemas = {
  [rpcMethods.aiGatewayAPIKeyForCreateOrFindByAgent]: {
    request: AIGatewayAPIKeyRequestSchema,
    response: AIGatewayAPIKeyResponseSchema
  },
  [rpcMethods.agentConversationContextResolve]: {
    request: AgentConversationContextRequestSchema,
    response: AgentConversationContextResponseSchema
  },
  [rpcMethods.actorTurnComplete]: {
    request: ActorTurnCompleteRequestSchema,
    response: ActorTurnCompleteResponseSchema
  },
  [rpcMethods.appConfigureResolve]: {
    request: AppConfigureResolveRequestSchema,
    response: AppConfigureResolveResponseSchema
  },
  [rpcMethods.agentPluginList]: {
    request: AgentPluginListRequestSchema,
    response: AgentPluginListResponseSchema
  },
  [rpcMethods.automationJobCreate]: {
    request: AutomationJobCreateRequestSchema,
    response: JSONPassthroughResponseSchema
  },
  [rpcMethods.automationJobList]: {
    request: AutomationJobListRequestSchema,
    response: JSONPassthroughResponseSchema
  },
  [rpcMethods.automationJobShow]: {
    request: AutomationJobShowRequestSchema,
    response: JSONPassthroughResponseSchema
  },
  [rpcMethods.automationJobCancel]: {
    request: AutomationJobTargetRequestSchema,
    response: JSONPassthroughResponseSchema
  },
  [rpcMethods.automationJobEmit]: {
    request: AutomationJobEmitRequestSchema,
    response: AutomationJobEmitResponseSchema
  },
  [rpcMethods.automationJobRun]: {
    request: AutomationJobRunRequestSchema,
    response: AutomationJobRunResponseSchema
  },
  [rpcMethods.backgroundAgentJobCreate]: {
    request: BackgroundAgentJobCreateRequestSchema,
    response: BackgroundAgentJobResponseSchema
  },
  [rpcMethods.backgroundAgentJobGet]: {
    request: BackgroundAgentJobGetRequestSchema,
    response: BackgroundAgentJobResponseSchema
  },
  [rpcMethods.backgroundAgentJobList]: {
    request: BackgroundAgentJobListRequestSchema,
    response: BackgroundAgentJobListResponseSchema
  },
  [rpcMethods.backgroundAgentJobMessageSend]: {
    request: BackgroundAgentJobMessageSendRequestSchema,
    response: BackgroundAgentJobMessageSendResponseSchema
  },
  [rpcMethods.backgroundAgentJobMessageResult]: {
    request: BackgroundAgentJobMessageResultRequestSchema,
    response: BackgroundAgentJobMessageResultResponseSchema
  },
  [rpcMethods.backgroundAgentJobRespawn]: {
    request: BackgroundAgentJobRespawnRequestSchema,
    response: BackgroundAgentJobRespawnResponseSchema
  },
  [rpcMethods.backgroundAgentJobStop]: {
    request: BackgroundAgentJobStopRequestSchema,
    response: BackgroundAgentJobStopResponseSchema
  },
  [rpcMethods.backgroundAgentJobTurnUpsert]: {
    request: BackgroundAgentJobTurnUpsertRequestSchema,
    response: BackgroundAgentJobTurnUpsertResponseSchema
  },
  [rpcMethods.backgroundAgentJobStatusUpdate]: {
    request: BackgroundAgentJobStatusUpdateRequestSchema,
    response: BackgroundAgentJobResponseSchema
  },
  [rpcMethods.memorySearch]: { request: MemorySearchRequestSchema, response: JSONPassthroughResponseSchema },
  [rpcMethods.memoryBrowse]: { request: MemoryBrowseRequestSchema, response: JSONPassthroughResponseSchema },
  [rpcMethods.memoryOpen]: { request: MemoryOpenRequestSchema, response: JSONPassthroughResponseSchema },
  [rpcMethods.memoryUpdate]: { request: MemoryUpdateRequestSchema, response: JSONPassthroughResponseSchema },
  [rpcMethods.memoryHealthCheck]: {
    request: MemoryHealthCheckRequestSchema,
    response: JSONPassthroughResponseSchema
  },
  [rpcMethods.scheduleCheckBackLaterCreate]: {
    request: ScheduleCheckBackLaterCreateRequestSchema,
    response: JSONPassthroughResponseSchema
  },
  [rpcMethods.scheduleCheckBackLaterList]: {
    request: ScheduleCheckBackLaterListRequestSchema,
    response: JSONPassthroughResponseSchema
  },
  [rpcMethods.scheduleCheckBackLaterGet]: {
    request: ScheduleCheckBackLaterTargetRequestSchema,
    response: JSONPassthroughResponseSchema
  },
  [rpcMethods.scheduleCheckBackLaterUpdate]: {
    request: ScheduleCheckBackLaterUpdateRequestSchema,
    response: JSONPassthroughResponseSchema
  },
  [rpcMethods.scheduleCheckBackLaterCancel]: {
    request: ScheduleCheckBackLaterTargetRequestSchema,
    response: JSONPassthroughResponseSchema
  },
  [rpcMethods.scheduleCronList]: { request: ScheduleCronListRequestSchema, response: JSONPassthroughResponseSchema },
  [rpcMethods.scheduleCronGet]: { request: ScheduleCronTargetRequestSchema, response: JSONPassthroughResponseSchema },
  [rpcMethods.scheduleCronRuns]: { request: ScheduleCronRunsRequestSchema, response: JSONPassthroughResponseSchema },
  [rpcMethods.scheduleCronAdd]: { request: ScheduleCronAddRequestSchema, response: JSONPassthroughResponseSchema },
  [rpcMethods.scheduleCronUpdate]: {
    request: ScheduleCronUpdateRequestSchema,
    response: JSONPassthroughResponseSchema
  },
  [rpcMethods.scheduleCronPause]: {
    request: ScheduleCronTargetRequestSchema,
    response: JSONPassthroughResponseSchema
  },
  [rpcMethods.scheduleCronResume]: {
    request: ScheduleCronTargetRequestSchema,
    response: JSONPassthroughResponseSchema
  },
  [rpcMethods.scheduleCronRemove]: {
    request: ScheduleCronTargetRequestSchema,
    response: JSONPassthroughResponseSchema
  },
  [rpcMethods.scheduleCronRun]: { request: ScheduleCronRunRequestSchema, response: JSONPassthroughResponseSchema },
  [rpcMethods.signalChannelAmbientJudgmentRecord]: {
    request: AmbientJudgmentRecordRequestSchema,
    response: JSONPassthroughResponseSchema
  },
  [rpcMethods.signalChannelStandingOrdersSet]: {
    request: SignalChannelStandingOrdersSetRequestSchema,
    response: JSONPassthroughResponseSchema
  },
  [rpcMethods.webhookEndpointCreate]: {
    request: WebhookEndpointCreateRequestSchema,
    response: JSONPassthroughResponseSchema
  },
  [rpcMethods.webhookEndpointList]: {
    request: WebhookEndpointListRequestSchema,
    response: JSONPassthroughResponseSchema
  },
  [rpcMethods.webhookEndpointCancel]: {
    request: WebhookEndpointTargetRequestSchema,
    response: JSONPassthroughResponseSchema
  },
  [rpcMethods.skillsInstalledReplace]: {
    request: InstalledSkillReplaceRequestSchema,
    response: InstalledSkillReplaceResponseSchema
  },
  [rpcMethods.skillsOverlayAppend]: { request: SkillOverlayAppendRequestSchema, response: SkillOverlayResponseSchema },
  [rpcMethods.skillsOverlayResolve]: {
    request: SkillOverlayResolveRequestSchema,
    response: SkillOverlayResponseSchema
  },
  [rpcMethods.skillsOverlayReplace]: {
    request: SkillOverlayReplaceRequestSchema,
    response: SkillOverlayResponseSchema
  },
  [rpcMethods.workerEnvResolve]: {
    request: WorkerEnvResolveRequestSchema,
    response: WorkerEnvResolveResponseSchema
  }
} as const satisfies Record<RPCMethod, { request: DescMessage; response: DescMessage }>

export type RPCRequestInit<M extends RPCMethod> = MessageInitShape<(typeof rpcSchemas)[M]['request']>
export type RPCResponseOf<M extends RPCMethod> = MessageShape<(typeof rpcSchemas)[M]['response']>
export type WorkerOwnedRPCMethod = {
  [M in RPCMethod]: (typeof rpcOperationMeta)[M] extends { owner: 'worker' } ? M : never
}[RPCMethod]
export type ControlPlaneOwnedRPCMethod = Exclude<RPCMethod, WorkerOwnedRPCMethod>

/** Frame routing facts for one call, enforced per operation scope. */
export type TurnRPCFrame = { turn: ActorTurnRef }
export type WorkerAgentRPCFrame = { agentUid: string }
export type RPCFrame<M extends ControlPlaneOwnedRPCMethod> = (typeof rpcOperationMeta)[M] extends { scope: 'turn' }
  ? TurnRPCFrame
  : WorkerAgentRPCFrame

/**
 * Shape of the injected RPC caller every turn capability goes through. It
 * generates request ids, converts control-plane rejections into thrown
 * `RPCRejectedError`s, and never applies local fallback behavior.
 */
export type RPCRequester = <M extends ControlPlaneOwnedRPCMethod>(
  method: M,
  payload: RPCRequestInit<M>,
  frame: RPCFrame<M>
) => Promise<RPCResponseOf<M>>

export type ScheduleRPCMethod = Extract<RPCMethod, `schedule.${string}`>
export type MemoryRPCMethod = Extract<RPCMethod, `memory${string}`>
export type WebhookRPCMethod = Extract<RPCMethod, `webhook.${string}`>
export type SignalChannelRPCMethod = Extract<RPCMethod, `signal_channel.${string}`>
export type AutomationJobManagementRPCMethod =
  | typeof rpcMethods.automationJobCreate
  | typeof rpcMethods.automationJobList
  | typeof rpcMethods.automationJobShow
  | typeof rpcMethods.automationJobCancel

/**
 * Family-scoped requesters injected into schedule and memory tools. The turn
 * fence is bound at construction; responses in these families are
 * model-facing passthrough JSON.
 */
export type ScheduleRPCRequester = <M extends ScheduleRPCMethod>(
  method: M,
  payload: RPCRequestInit<M>
) => Promise<JSONObject>

export type MemoryRPCRequester = <M extends MemoryRPCMethod>(
  method: M,
  payload: RPCRequestInit<M>
) => Promise<JSONObject>

export type WebhookRPCRequester = <M extends WebhookRPCMethod>(
  method: M,
  payload: RPCRequestInit<M>
) => Promise<JSONObject>

export type SignalChannelRPCRequester = <M extends SignalChannelRPCMethod>(
  method: M,
  payload: RPCRequestInit<M>
) => Promise<JSONObject>

export type AutomationJobRPCRequester = <M extends AutomationJobManagementRPCMethod>(
  method: M,
  payload: RPCRequestInit<M>
) => Promise<JSONObject>

export function scheduleRPCRequester(rpc: RPCRequester, turn: ActorTurnRef): ScheduleRPCRequester {
  // Every schedule method is turn-scoped; the conditional frame type cannot
  // be discharged over a generic method union.
  return async (method, payload) =>
    passthroughJSON(await rpc(method, payload, { turn } as RPCFrame<typeof method>), method)
}

export function memoryRPCRequester(rpc: RPCRequester, turn: ActorTurnRef): MemoryRPCRequester {
  // Every memory method is turn-scoped; same discharge limit as above.
  return async (method, payload) =>
    passthroughJSON(await rpc(method, payload, { turn } as RPCFrame<typeof method>), method)
}

export function webhookRPCRequester(rpc: RPCRequester, turn: ActorTurnRef): WebhookRPCRequester {
  // Every webhook method is turn-scoped; same discharge limit as above.
  return async (method, payload) =>
    passthroughJSON(await rpc(method, payload, { turn } as RPCFrame<typeof method>), method)
}

export function signalChannelRPCRequester(rpc: RPCRequester, turn: ActorTurnRef): SignalChannelRPCRequester {
  // Every signal_channel method is turn-scoped; same discharge limit as above.
  return async (method, payload) =>
    passthroughJSON(await rpc(method, payload, { turn } as RPCFrame<typeof method>), method)
}

export function automationJobRPCRequester(rpc: RPCRequester, turn: ActorTurnRef): AutomationJobRPCRequester {
  return async (method, payload) =>
    passthroughJSON(await rpc(method, payload, { turn } as RPCFrame<typeof method>), method)
}

function passthroughJSON(response: { bodyJson: Uint8Array }, method: string): JSONObject {
  return jsonObjectFromBytes(response.bodyJson, `${method} body_json`) ?? {}
}

/** Control-plane rejection frame of one RPC call. */
export type RPCRejection = {
  code: string
  message?: string
  details?: JSONObject
}

export function rpcRejectionFromError(error: RPCErrorMessage): RPCRejection {
  return {
    code: error.code,
    ...(error.message ? { message: error.message } : {}),
    ...(() => {
      const details = jsonObjectFromBytes(error.detailsJson, 'rpc_error.details_json')
      return details ? { details } : {}
    })()
  }
}

export function rpcRejectedMessage(label: string, rejection: { code: string; message?: string }): string {
  return `${label}: ${rejection.code} ${rejection.message ?? ''}`.trim()
}

/**
 * Thrown when the control plane rejects an RPC operation. Carries the
 * rejection frame so callers that map rejection codes onto domain errors keep
 * typed access instead of parsing the message.
 */
export class RPCRejectedError extends Error {
  constructor(
    label: string,
    readonly rejection: RPCRejection
  ) {
    super(rpcRejectedMessage(label, rejection))
  }
}

export class RPCTimeoutError extends Error {
  constructor(readonly method: RPCMethod) {
    super(`RPC request timed out: ${method}`)
    this.name = 'RPCTimeoutError'
  }
}

const defaultRPCTimeoutMs = 300_000

type RPCWaiter = {
  resolve: (reply: RPCResponseMessage | RPCErrorMessage) => void
  reject: (error: Error) => void
  timeout: ReturnType<typeof setTimeout>
}

/**
 * Generates the wire request id for one RPC call. The id is an opaque
 * correlation token; the method-derived prefix only aids log reading.
 */
function rpcRequestID(method: RPCMethod): string {
  return `${method.replaceAll(/[^a-zA-Z0-9]+/g, '-')}-${crypto.randomUUID()}`
}

/**
 * Tracks worker-originated RuntimeFabric RPC calls until the matching
 * response or error envelope arrives.
 *
 * This is the single codec boundary for RPC payloads on the worker: requests
 * are encoded and responses decoded through the `rpcSchemas` registry, so a
 * successful decode is the payload validation. RPC is control-lane traffic,
 * not durable actor truth; the timeout prevents a missing control-plane
 * reply from parking the turn loop forever.
 */
export class RuntimeRPCClient {
  private waiters = new Map<string, RPCWaiter>()
  private readonly timeoutMs: number

  constructor(
    private readonly sendEnvelope: EnvelopeSender,
    options: { timeoutMs?: number } = {}
  ) {
    this.timeoutMs = options.timeoutMs ?? defaultRPCTimeoutMs
  }

  /**
   * Sends one typed RPC request and waits for its reply.
   *
   * Returns the decoded response message for the operation, or the rejection
   * frame when the control plane answered with `rpc_error`.
   */
  async request<M extends ControlPlaneOwnedRPCMethod>(
    method: M,
    payload: RPCRequestInit<M>,
    frame: RPCFrame<M>,
    options: { timeoutMs?: number } = {}
  ): Promise<RPCResponseOf<M> | RPCRejection> {
    const requestID = rpcRequestID(method)
    const schema = rpcSchemas[method]
    // The compiler cannot correlate rpcSchemas[M] request/response pairs
    // through a generic M, so payload narrowing happens here once.
    const requestBytes = toBinary(schema.request, create(schema.request, payload as MessageInitShape<DescMessage>))

    const promise = new Promise<RPCResponseMessage | RPCErrorMessage>((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.waiters.delete(requestID)
        reject(new RPCTimeoutError(method))
      }, options.timeoutMs ?? this.timeoutMs)
      this.waiters.set(requestID, { resolve, reject, timeout })
    })

    try {
      await this.sendEnvelope(
        createEnvelope({
          ...envelopeHeader(
            `rpc-request-${crypto.randomUUID()}`,
            Lane.RPC,
            DurabilityClass.CONTROL_EPHEMERAL,
            requestID
          ),
          body: {
            case: 'rpcRequest',
            value: create(RPCRequestSchema, {
              requestId: requestID,
              method,
              payload: requestBytes,
              ...('turn' in frame ? { turn: actorTurnRefToProto(frame.turn) } : { agentUid: frame.agentUid })
            })
          }
        })
      )
    } catch (error) {
      const waiter = this.waiters.get(requestID)
      if (waiter) {
        clearTimeout(waiter.timeout)
        this.waiters.delete(requestID)
      }
      throw error
    }

    const reply = await promise
    if (reply.$typeName === 'ankole.runtime_fabric.v1.RPCError') {
      return rpcRejectionFromError(reply)
    }
    return fromBinary(schema.response, reply.payload) as RPCResponseOf<M>
  }

  /**
   * Resolves a pending waiter from an incoming RPC response or error envelope.
   */
  resolve(reply: RPCResponseMessage | RPCErrorMessage): void {
    const waiter = this.waiters.get(reply.requestId)
    if (!waiter) return

    clearTimeout(waiter.timeout)
    this.waiters.delete(reply.requestId)
    waiter.resolve(reply)
  }
}

export type WorkerRPCHandlers = {
  runAutomationJob: (
    request: MessageShape<typeof AutomationJobRunRequestSchema>
  ) => Promise<MessageInitShape<typeof AutomationJobRunResponseSchema>>
}

/**
 * Handles a control-plane-originated RPC request through the worker-owned
 * operation table.
 */
export async function handleWorkerRPCRequest(
  sendEnvelope: EnvelopeSender,
  request: RPCRequestMessage,
  handlers?: WorkerRPCHandlers
): Promise<void> {
  if (request.method === rpcMethods.automationJobRun && handlers) {
    try {
      const payload = fromBinary(AutomationJobRunRequestSchema, request.payload)
      const result = await handlers.runAutomationJob(payload)
      await sendWorkerRPCResponse(
        sendEnvelope,
        request,
        toBinary(AutomationJobRunResponseSchema, create(AutomationJobRunResponseSchema, result))
      )
    } catch (error) {
      await sendWorkerRPCError(sendEnvelope, request, 'worker_rpc_failed', errorMessage(error), {
        method: request.method
      })
    }
    return
  }

  await sendWorkerRPCError(
    sendEnvelope,
    request,
    'unknown_rpc_method',
    `unknown worker RPC method: ${request.method}`,
    { method: request.method }
  )
}

async function sendWorkerRPCResponse(
  sendEnvelope: EnvelopeSender,
  request: RPCRequestMessage,
  payload: Uint8Array
): Promise<void> {
  await sendEnvelope(
    createEnvelope({
      ...envelopeHeader(
        `rpc-reply-${crypto.randomUUID()}`,
        Lane.RPC,
        DurabilityClass.CONTROL_EPHEMERAL,
        request.requestId
      ),
      body: {
        case: 'rpcResponse',
        value: create(RPCResponseSchema, {
          requestId: request.requestId,
          payload
        })
      }
    })
  )
}

async function sendWorkerRPCError(
  sendEnvelope: EnvelopeSender,
  request: RPCRequestMessage,
  code: string,
  message: string,
  details: JSONObject
): Promise<void> {
  await sendEnvelope(
    createEnvelope({
      ...envelopeHeader(
        `rpc-reply-${crypto.randomUUID()}`,
        Lane.RPC,
        DurabilityClass.CONTROL_EPHEMERAL,
        request.requestId
      ),
      body: {
        case: 'rpcError',
        value: create(RPCErrorSchema, {
          requestId: request.requestId,
          code,
          message,
          detailsJson: jsonBytes(details)
        })
      }
    })
  )
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

/**
 * Generated payload message types re-exported under the lane contract so
 * consumers do not import the generated module path directly.
 */
export { RuntimeSkillSummarySchema } from '../fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
export type {
  AgentConversationContextResponse,
  AgentPluginCatalogEntry,
  AgentPluginCatalogSkill,
  AgentPluginListResponse,
  AIGatewayAPIKeyResponse,
  AppConfigureResolution,
  AppConfigureResolveResponse,
  AutomationJobRunRequest,
  AutomationJobRunResponse,
  BackgroundAgentJobAttemptHistoryEntry,
  BackgroundAgentJobListResponse,
  BackgroundAgentJobMessageResultResponse,
  BackgroundAgentJobMessageSendResponse,
  ConversationChannel,
  BackgroundAgentJobRespawnResponse,
  BackgroundAgentJobResponse,
  BackgroundAgentJobResultRef,
  BackgroundAgentJobSummary,
  BackgroundAgentJobStopResponse,
  BackgroundAgentJobTurn,
  BackgroundAgentJobTurnUpsertRequest,
  BackgroundAgentJobTurnUpsertResponse,
  BrainSnapshot,
  BrainSnapshotEntry,
  InstalledSkillObservation,
  InstalledSkillReplaceResponse,
  MemoryUpdateRequest,
  RuntimeSkillSummary,
  SkillOverlayResponse,
  WorkerEnvResolveResponse
} from '../fabric/generated/ankole/runtime_fabric/v1/rpc_pb'

/**
 * Hand-written shapes of the deliberately free-form `*_json` documents the
 * worker produces or consumes inside the generated messages. They are
 * documentation-grade contracts: the control plane persists them as JSON and
 * the model reads their rendered form.
 */
export type BackgroundAgentJobStatus = 'queued' | 'running' | 'waiting_on_user' | 'succeeded' | 'failed' | 'stopped'

export type BackgroundAgentJobTurnStatus = 'in_progress' | 'completed' | 'failed' | 'interrupted'
export type BackgroundAgentJobTurnKind = 'agent' | 'compaction'

export type BackgroundAgentJobTurnTrajectoryContentPart = JSONObject & {
  type: string
}

export type BackgroundAgentJobTurnTrajectoryToolCall = JSONObject & {
  id: string
  type: 'function'
  function: JSONObject & {
    name: string
    arguments: string
  }
}

export type BackgroundAgentJobTurnTrajectoryMessage =
  | (JSONObject & {
      id?: string
      role: 'user' | 'developer'
      content: string | BackgroundAgentJobTurnTrajectoryContentPart[]
      metadata?: JSONObject
    })
  | (JSONObject & {
      id?: string
      role: 'assistant'
      content: string
      tool_calls?: BackgroundAgentJobTurnTrajectoryToolCall[]
      metadata?: JSONObject
    })
  | (JSONObject & {
      id?: string
      role: 'tool'
      tool_call_id: string
      name: string
      content: string
      metadata?: JSONObject
    })

export type BackgroundAgentJobTurnTrajectoryMetadata = JSONObject & {
  redacted?: boolean
  content_truncated?: boolean
}

export type BackgroundAgentJobTurnTrajectory = JSONObject & {
  format: 'ankole_chatml'
  version: 1
  messages: BackgroundAgentJobTurnTrajectoryMessage[]
  metadata?: BackgroundAgentJobTurnTrajectoryMetadata
}

export type BackgroundAgentJobTurnTrajectoryHeader = JSONObject & {
  format: 'ankole_chatml'
  version: 1
  metadata?: BackgroundAgentJobTurnTrajectoryMetadata
}

export type BackgroundAgentJobTurnTrajectoryGroup = JSONObject & {
  position: number
  item_key: string
  messages: BackgroundAgentJobTurnTrajectoryMessage[]
}

export type BackgroundAgentJobTurnUsageBreakdown = JSONObject & {
  total_tokens: number
  input_tokens: number
  cached_input_tokens: number
  output_tokens: number
  reasoning_output_tokens: number
}

export type BackgroundAgentJobTurnUsage = JSONObject & {
  thread_total: BackgroundAgentJobTurnUsageBreakdown
  last_model_call: BackgroundAgentJobTurnUsageBreakdown
  model_context_window?: number
}

export type BackgroundAgentJobTurnPlan = JSONObject & {
  explanation?: string
  steps: Array<
    JSONObject & {
      step: string
      status: 'pending' | 'in_progress' | 'completed'
    }
  >
}

export type BackgroundAgentJobTurnToolUsage = JSONObject & {
  name: string
  calls: number
}

export type BackgroundAgentJobTurnActiveItem = JSONObject & {
  id: string
  name: string
}

export type BackgroundAgentJobTurnProgress = JSONObject & {
  completed_items: number
  tool_calls: number
  tools_used: BackgroundAgentJobTurnToolUsage[]
  files_changed: string[]
  plan?: BackgroundAgentJobTurnPlan
  active_item?: BackgroundAgentJobTurnActiveItem
}

export type BackgroundAgentJobExecution = {
  attempt: number
  current?: {
    runtime_turn_id: string
    kind: BackgroundAgentJobTurnKind
    status: BackgroundAgentJobTurnStatus
  }
  lead_turn_number: number
  threads: { total: number; child: number }
  turns: { lead: number; child: number; compaction: number; active: number }
  progress: Omit<BackgroundAgentJobTurnProgress, 'active_item'> & {
    active_items: Array<{ scope: 'lead' | 'child'; name: string }>
  }
  usage?: BackgroundAgentJobTurnUsage
  trajectory_page: BackgroundAgentJobTurnTrajectory & { next_cursor?: string }
  updated_at: string
}
