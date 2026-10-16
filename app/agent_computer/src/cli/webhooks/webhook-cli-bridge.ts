import type { JsonObject as JSONObject } from '@agentbull/active-support'
import type { RPCMethod, RPCRequestInit } from '../../lanes/rpc_contract'
import { type RPCRequester, type RPCFrame } from '../../lanes/rpc_lane'
import type { RunRef, JobTurnRef } from '../../lanes/session_lane'
import { jsonObjectFromBytes } from '../../fabric/envelope_proto'

export type WebhookRPCMethod = Extract<RPCMethod, `webhook.${string}`>
export type WebhookRPCRequester = <M extends WebhookRPCMethod>(
  method: M,
  payload: RPCRequestInit<M>
) => Promise<JSONObject>

/** Binds this CLI family to its caller's turn; only reads may repeat after disconnect. */
export function webhookRPCRequester(rpc: RPCRequester, turn: JobTurnRef | RunRef): WebhookRPCRequester {
  const frame = 'job_id' in turn ? { jobTurn: turn } : { run: turn }
  return async (method, payload) => {
    const response = await rpc(method, payload, frame as RPCFrame<typeof method>, {
      retryOnDisconnect: method === 'webhook.endpoint.list'
    })
    return jsonObjectFromBytes(response.bodyJson, `${method} body_json`) ?? {}
  }
}

import { randomUUID } from 'node:crypto'
import { join } from 'node:path'
import { WORKER_SHARE_ROOT } from '../../core/agent-home-paths'
import {
  CLI_REQUEST_MAX_BYTES,
  parseCLIRequest,
  startSocketLineBridge,
  type SocketLineBridge,
  type SocketLineBridgeResponse
} from '../../core/socket-line-bridge'
import { WebhookCLICommand } from './webhook-cli-protocol'

/**
 * The bridge binds every request to the current turn before it uses the
 * existing RuntimeFabric requester, so the CLI never receives the worker auth
 * key or fabric endpoint.
 */
export function startWebhookCLIBridge(opts: {
  requestWebhookRPC: WebhookRPCRequester
  socketRoot?: string
}): SocketLineBridge {
  return startSocketLineBridge({
    socketPath: join(opts.socketRoot ?? WORKER_SHARE_ROOT, `ankole-wh-${randomUUID()}.sock`),
    maxRequestBytes: CLI_REQUEST_MAX_BYTES,
    oversizeError: 'webhook CLI request is too large',
    handleLine: line => executeLine(line, opts)
  })
}

async function executeLine(
  line: string,
  opts: {
    requestWebhookRPC: WebhookRPCRequester
  }
): Promise<SocketLineBridgeResponse> {
  const command = parseCLIRequest(line, WebhookCLICommand, 'webhook CLI request must be one JSON object')
  const call = opts.requestWebhookRPC

  if (command.operation === 'create') {
    const result = await call('webhook.endpoint.create', {
      label: command.label,
      mode: command.mode,
      expiresAt: command.expires_at,
      ...(command.automation_job_id === undefined ? {} : { automationJobId: String(command.automation_job_id) })
    })
    return { ok: true, result }
  }

  if (command.operation === 'list') {
    const result = await call('webhook.endpoint.list', command.limit ? { limit: command.limit } : {})
    return { ok: true, result }
  }

  const result = await call('webhook.endpoint.cancel', {
    webhookEndpointId: command.webhook_endpoint_id
  })
  return { ok: true, result }
}
