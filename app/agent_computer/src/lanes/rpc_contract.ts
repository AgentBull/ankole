import type { DescMessage, MessageInitShape, MessageShape } from '@bufbuild/protobuf'
import {
  FilesCommitRequestSchema,
  FilesCommitResponseSchema,
  FilesGetRequestSchema,
  FilesGetResponseSchema,
  FilesListRequestSchema,
  FilesListResponseSchema,
  PodRequestSchema,
  AIGatewayAPIKeyRequestSchema,
  AIGatewayAPIKeyResponseSchema,
  ActorTurnAbortRequestSchema,
  ActorTurnAbortResponseSchema,
  AutomationJobCreateRequestSchema,
  AutomationJobEmitRequestSchema,
  AutomationJobEmitResponseSchema,
  AutomationJobListRequestSchema,
  AutomationJobRunRequestSchema,
  AutomationJobRunResponseSchema,
  AutomationJobShowRequestSchema,
  AutomationJobTargetRequestSchema,
  BackgroundAgentJobGetRequestSchema,
  BackgroundAgentJobResponseSchema,
  BackgroundAgentJobStatusUpdateRequestSchema,
  BackgroundAgentJobTurnItemsListRequestSchema,
  BackgroundAgentJobTurnItemsListResponseSchema,
  BackgroundAgentJobTurnUpsertRequestSchema,
  BackgroundAgentJobTurnUpsertResponseSchema,
  JSONPassthroughResponseSchema,
  ObservabilitySpansExportRequestSchema,
  ObservabilitySpansExportResponseSchema,
  ReadToolRequestSchema,
  WebhookEndpointCreateRequestSchema,
  WebhookEndpointListRequestSchema,
  WebhookEndpointTargetRequestSchema,
  WorkerEnvResolveRequestSchema,
  WorkerEnvResolveResponseSchema,
  WorkerFileTransferRequestSchema,
  WorkerFileTransferResponseSchema
} from '../fabric/generated/ankole/runtime_fabric/v1/rpc_pb'

/**
 * The operation table owns method names, authorization and payload schemas.
 * Add messages and generate proto, add a row and generate rpc_methods.json,
 * then add the control-plane broker mapping and its function clause.
 */
export type RPCOperation =
  | { scope: 'worker_agent'; request: DescMessage; response: DescMessage }
  | {
      scope: 'turn' | 'turn_or_automation'
      effect: 'read' | 'write' | 'complete'
      request: DescMessage
      response: DescMessage
    }
  | { owner: 'worker'; handler: keyof WorkerRPCHandlers; request: DescMessage; response: DescMessage }

export const rpcOperations = {
  'pod.read': {
    scope: 'turn_or_automation',
    effect: 'read',
    request: PodRequestSchema,
    response: JSONPassthroughResponseSchema
  },
  'pod.write': {
    scope: 'turn_or_automation',
    effect: 'write',
    request: PodRequestSchema,
    response: JSONPassthroughResponseSchema
  },
  'session_turn.abort': {
    scope: 'turn',
    effect: 'complete',
    request: ActorTurnAbortRequestSchema,
    response: ActorTurnAbortResponseSchema
  },
  'ai_gateway.api_key_for.create_or_find_by_agent': {
    scope: 'worker_agent',
    request: AIGatewayAPIKeyRequestSchema,
    response: AIGatewayAPIKeyResponseSchema
  },
  'automation_job.cancel': {
    scope: 'turn',
    effect: 'write',
    request: AutomationJobTargetRequestSchema,
    response: JSONPassthroughResponseSchema
  },
  'automation_job.create': {
    scope: 'turn',
    effect: 'write',
    request: AutomationJobCreateRequestSchema,
    response: JSONPassthroughResponseSchema
  },
  'automation_job.emit': {
    scope: 'worker_agent',
    request: AutomationJobEmitRequestSchema,
    response: AutomationJobEmitResponseSchema
  },
  'automation_job.list': {
    scope: 'turn',
    effect: 'read',
    request: AutomationJobListRequestSchema,
    response: JSONPassthroughResponseSchema
  },
  'automation_job.run': {
    owner: 'worker',
    handler: 'runAutomationJob',
    request: AutomationJobRunRequestSchema,
    response: AutomationJobRunResponseSchema
  },
  'automation_job.show': {
    scope: 'turn',
    effect: 'read',
    request: AutomationJobShowRequestSchema,
    response: JSONPassthroughResponseSchema
  },
  'background_agent_job.get': {
    scope: 'turn',
    effect: 'read',
    request: BackgroundAgentJobGetRequestSchema,
    response: BackgroundAgentJobResponseSchema
  },
  'background_agent_job.status.update': {
    scope: 'turn',
    effect: 'complete',
    request: BackgroundAgentJobStatusUpdateRequestSchema,
    response: BackgroundAgentJobResponseSchema
  },
  'background_agent_job.turn.upsert': {
    scope: 'turn',
    effect: 'write',
    request: BackgroundAgentJobTurnUpsertRequestSchema,
    response: BackgroundAgentJobTurnUpsertResponseSchema
  },
  'background_agent_job.turn_items.list': {
    scope: 'turn',
    effect: 'read',
    request: BackgroundAgentJobTurnItemsListRequestSchema,
    response: BackgroundAgentJobTurnItemsListResponseSchema
  },
  'files.commit': { scope: 'worker_agent', request: FilesCommitRequestSchema, response: FilesCommitResponseSchema },
  'files.get': { scope: 'worker_agent', request: FilesGetRequestSchema, response: FilesGetResponseSchema },
  'files.list': { scope: 'worker_agent', request: FilesListRequestSchema, response: FilesListResponseSchema },
  'observability.spans.export': {
    scope: 'worker_agent',
    request: ObservabilitySpansExportRequestSchema,
    response: ObservabilitySpansExportResponseSchema
  },
  'tools.read': {
    scope: 'turn',
    effect: 'read',
    request: ReadToolRequestSchema,
    response: JSONPassthroughResponseSchema
  },
  'webhook.endpoint.cancel': {
    scope: 'turn',
    effect: 'write',
    request: WebhookEndpointTargetRequestSchema,
    response: JSONPassthroughResponseSchema
  },
  'webhook.endpoint.create': {
    scope: 'turn',
    effect: 'write',
    request: WebhookEndpointCreateRequestSchema,
    response: JSONPassthroughResponseSchema
  },
  'webhook.endpoint.list': {
    scope: 'turn',
    effect: 'read',
    request: WebhookEndpointListRequestSchema,
    response: JSONPassthroughResponseSchema
  },
  'worker_env.resolve': {
    scope: 'worker_agent',
    request: WorkerEnvResolveRequestSchema,
    response: WorkerEnvResolveResponseSchema
  },
  'worker_files.pull': {
    owner: 'worker',
    handler: 'pullWorkerFile',
    request: WorkerFileTransferRequestSchema,
    response: WorkerFileTransferResponseSchema
  },
  'worker_files.push': {
    owner: 'worker',
    handler: 'pushWorkerFile',
    request: WorkerFileTransferRequestSchema,
    response: WorkerFileTransferResponseSchema
  }
} as const satisfies Record<string, RPCOperation>
export type RPCMethod = keyof typeof rpcOperations

export type RPCRequestInit<M extends RPCMethod> = MessageInitShape<(typeof rpcOperations)[M]['request']>
export type RPCResponseOf<M extends RPCMethod> = MessageShape<(typeof rpcOperations)[M]['response']>
export type WorkerOwnedRPCMethod = {
  [M in RPCMethod]: (typeof rpcOperations)[M] extends { owner: 'worker' } ? M : never
}[RPCMethod]
export type ControlPlaneOwnedRPCMethod = Exclude<RPCMethod, WorkerOwnedRPCMethod>

/** One worker-owned operation: the handler that runs it and how its result is reported. */
export type WorkerRPCContext = { deadlineUnixMs: number; signal: AbortSignal }

export type WorkerRPCHandler<M extends WorkerOwnedRPCMethod> = (
  request: MessageShape<(typeof rpcOperations)[M]['request']>,
  context: WorkerRPCContext
) => Promise<MessageInitShape<(typeof rpcOperations)[M]['response']>>

export type WorkerRPCHandlers = {
  runAutomationJob?: WorkerRPCHandler<'automation_job.run'>
  pullWorkerFile?: WorkerRPCHandler<'worker_files.pull'>
  pushWorkerFile?: WorkerRPCHandler<'worker_files.push'>
}
