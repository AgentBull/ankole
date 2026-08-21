import { randomBytes, randomUUID } from 'node:crypto'
import { join } from 'node:path'
import { jsonBytes } from '../../fabric/envelope_proto'
import type { TurnStart } from '../../lanes/actor_lane'
import { rpcMethods, type WebhookRPCRequester } from '../../lanes/rpc_lane'
import { WORKER_SHARE_ROOT } from '../../core/agent-home-paths'
import {
  startSocketLineBridge,
  type SocketLineBridge,
  type SocketLineBridgeResponse
} from '../../core/socket-line-bridge'
import { currentReplyRoute } from '../../core/turns/reply_route'
import { WebhookCLICommand } from './webhook-cli-protocol'

const maxCommandBytes = 16 * 1024

/**
 * Starts the turn-local bridge used by the shell webhook CLIs.
 *
 * The bridge binds every request to the current turn before it uses the
 * existing RuntimeFabric requester, so the CLI never receives the worker auth
 * key or fabric endpoint.
 */
export function startWebhookCLIBridge(opts: {
  turnStart: TurnStart
  requestWebhookRPC: WebhookRPCRequester
  socketRoot?: string
}): SocketLineBridge {
  return startSocketLineBridge({
    socketPath: join(opts.socketRoot ?? WORKER_SHARE_ROOT, `ankole-wh-${randomUUID()}.sock`),
    maxRequestBytes: maxCommandBytes,
    oversizeError: 'webhook CLI request is too large',
    handleLine: line => executeLine(line, opts)
  })
}

async function executeLine(
  line: string,
  opts: {
    turnStart: TurnStart
    requestWebhookRPC: WebhookRPCRequester
  }
): Promise<SocketLineBridgeResponse> {
  let raw: unknown

  try {
    raw = JSON.parse(line)
  } catch {
    return { ok: false, error: 'webhook CLI request must be one JSON object' }
  }

  const parsed = WebhookCLICommand.safeParse(raw)
  if (!parsed.success) {
    return { ok: false, error: parsed.error.issues.map(issue => issue.message).join('; ') }
  }

  const command = parsed.data
  const call = opts.requestWebhookRPC

  if (command.operation === 'create') {
    const replyRoute = currentReplyRoute(opts.turnStart)
    if (!replyRoute) {
      return {
        ok: false,
        error: 'create-webhook-cli requires a provider reply route from the current turn'
      }
    }

    const token = `wh_${randomBytes(32).toString('base64url')}`
    const result = await call(rpcMethods.webhookEndpointCreate, {
      token,
      label: command.label,
      mode: command.mode,
      expiresAt: command.expires_at,
      replyRouteJson: jsonBytes(replyRoute),
      ...(command.automation_job_id === undefined ? {} : { automationJobId: String(command.automation_job_id) })
    })
    return { ok: true, result }
  }

  if (command.operation === 'list') {
    const result = await call(rpcMethods.webhookEndpointList, command.limit ? { limit: command.limit } : {})
    return { ok: true, result }
  }

  const result = await call(rpcMethods.webhookEndpointCancel, {
    webhookEndpointId: command.webhook_endpoint_id
  })
  return { ok: true, result }
}
