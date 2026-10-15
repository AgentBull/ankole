import { randomUUID } from 'node:crypto'
import { join } from 'node:path'
import { type WebhookRPCRequester } from '../../lanes/rpc_lane'
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
