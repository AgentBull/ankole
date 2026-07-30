import { chmodSync, existsSync, unlinkSync } from 'node:fs'
import { randomBytes, randomUUID } from 'node:crypto'
import { join } from 'node:path'
import { jsonBytes } from '../../fabric/envelope_proto'
import type { TurnStart } from '../../lanes/actor_lane'
import { rpcMethods, type WebhookRPCRequester } from '../../lanes/rpc_lane'
import { WORKER_SHARE_ROOT } from '../../core/agent-home-paths'
import { currentReplyRoute } from '../../core/turns/reply_route'
import { WebhookCLICommand, type WebhookCLIResponse } from './webhook-cli-protocol'

const maxCommandBytes = 16 * 1024

type SocketState = {
  buffer: string
  handled: boolean
}

export type WebhookCLIBridge = {
  socketPath: string
  close: () => void
}

/**
 * Starts the turn-local bridge used by the shell webhook CLIs.
 *
 * The random Unix socket path is the only shell-side capability. The bridge
 * binds every request to the current turn before it uses the existing
 * RuntimeFabric requester, so the CLI never receives the worker auth key or
 * fabric endpoint.
 */
export function startWebhookCLIBridge(opts: {
  turnStart: TurnStart
  requestWebhookRPC: WebhookRPCRequester
  socketRoot?: string
}): WebhookCLIBridge {
  const socketPath = join(opts.socketRoot ?? WORKER_SHARE_ROOT, `ankole-wh-${randomUUID()}.sock`)

  const listener = Bun.listen<SocketState>({
    unix: socketPath,
    socket: {
      open(socket) {
        socket.data = { buffer: '', handled: false }
      },
      data(socket, data) {
        if (socket.data.handled) return
        socket.data.buffer += Buffer.from(data).toString('utf8')

        if (Buffer.byteLength(socket.data.buffer, 'utf8') > maxCommandBytes) {
          socket.data.handled = true
          writeResponse(socket, { ok: false, error: 'webhook CLI request is too large' })
          return
        }

        const newline = socket.data.buffer.indexOf('\n')
        if (newline < 0) return

        socket.data.handled = true
        const line = socket.data.buffer.slice(0, newline)

        void executeLine(line, opts)
          .then(response => writeResponse(socket, response))
          .catch(error => writeResponse(socket, { ok: false, error: errorMessage(error) }))
      },
      error(_socket, _error) {
        // The caller receives a closed socket. RuntimeFabric and domain errors
        // are returned through the normal response path above.
      }
    }
  })

  chmodSync(socketPath, 0o600)
  let closed = false

  return {
    socketPath,
    close: () => {
      if (closed) return
      closed = true
      listener.stop(true)
      if (existsSync(socketPath)) unlinkSync(socketPath)
    }
  }
}

async function executeLine(
  line: string,
  opts: {
    turnStart: TurnStart
    requestWebhookRPC: WebhookRPCRequester
  }
): Promise<WebhookCLIResponse> {
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

function writeResponse(socket: Bun.Socket<SocketState>, response: WebhookCLIResponse): void {
  socket.write(`${JSON.stringify(response)}\n`)
  socket.end()
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
