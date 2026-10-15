/**
 * Turn-local Unix-socket line bridge for shell CLIs and the automation-job
 * SDK. The random socket path is the only shell-side capability: each
 * connection carries one newline-terminated JSON request and receives one
 * JSON response, so the shell never holds the worker auth key or fabric
 * endpoint.
 *
 * `src/automation-jobs/sdk.ts` keeps its own copy of the client half on
 * purpose — that file runs in the Automation script process as a
 * self-contained module and does not import Worker code.
 */

import { chmodSync, existsSync, unlinkSync } from 'node:fs'
import type { z } from 'zod'
import { errorMessage } from '../common/errors'
import { chownAgentPathSync } from '../common/agent-user'

/** Response envelope the CLI bridges write for every request. */
export type SocketLineBridgeResponse = { ok: true; result: Record<string, unknown> } | { ok: false; error: string }

/** Request limit of the CLI bridges. A CLI command is a small JSON object. */
export const CLI_REQUEST_MAX_BYTES = 16 * 1024

export type SocketLineBridge = {
  socketPath: string
  close: () => void
}

type SocketState = {
  buffer: Buffer
  handled: boolean
  response?: Buffer
}

export function startSocketLineBridge(opts: {
  socketPath: string
  maxRequestBytes: number
  oversizeError: string
  handleLine: (line: string) => Promise<unknown>
}): SocketLineBridge {
  const listener = Bun.listen<SocketState>({
    unix: opts.socketPath,
    socket: {
      open(socket) {
        socket.data = { buffer: Buffer.alloc(0), handled: false }
      },
      data(socket, data) {
        if (socket.data.handled) return
        socket.data.buffer = Buffer.concat([socket.data.buffer, data])

        if (socket.data.buffer.byteLength > opts.maxRequestBytes) {
          socket.data.handled = true
          writeResponse(socket, { ok: false, error: opts.oversizeError })
          return
        }

        const newline = socket.data.buffer.indexOf(0x0a)
        if (newline < 0) return

        socket.data.handled = true
        const line = socket.data.buffer.subarray(0, newline).toString('utf8')

        void opts
          .handleLine(line)
          .then(response => writeResponse(socket, response))
          .catch(error => writeResponse(socket, { ok: false, error: errorMessage(error) }))
      },
      drain: flushResponse,
      error(_socket, _error) {
        // The caller receives a closed socket. RuntimeFabric and domain errors
        // are returned through the normal response path above.
      }
    }
  })

  chmodSync(opts.socketPath, 0o600)
  chownAgentPathSync(opts.socketPath)
  let closed = false

  return {
    socketPath: opts.socketPath,
    close: () => {
      if (closed) return
      closed = true
      listener.stop(true)
      if (existsSync(opts.socketPath)) unlinkSync(opts.socketPath)
    }
  }
}

function writeResponse(socket: Bun.Socket<SocketState>, response: unknown): void {
  socket.data.response = Buffer.from(`${JSON.stringify(response)}\n`)
  flushResponse(socket)
}

function flushResponse(socket: Bun.Socket<SocketState>): void {
  const response = socket.data.response
  if (!response) return
  const written = socket.write(response)
  if (written < 0) {
    socket.data.response = undefined
    return
  }
  if (written < response.byteLength) {
    socket.data.response = response.subarray(written)
    return
  }
  socket.data.response = undefined
  socket.end()
}

/** A thrown error goes back to the CLI as `{ ok: false, error }`. */
export function parseCLIRequest<Schema extends z.ZodType>(
  line: string,
  schema: Schema,
  invalidJSONError: string
): z.output<Schema> {
  let raw: unknown
  try {
    raw = JSON.parse(line)
  } catch {
    throw new Error(invalidJSONError)
  }
  const parsed = schema.safeParse(raw)
  if (!parsed.success) throw new Error(parsed.error.issues.map(issue => issue.message).join('; '))
  return parsed.data
}

export async function requestSocketLineBridge(
  socketPath: string,
  line: string,
  invalidResponseError: string
): Promise<Record<string, unknown>> {
  const decoded = await new Promise<SocketLineBridgeResponse>((resolve, reject) => {
    const response: Buffer[] = []
    let settled = false

    void Bun.connect({
      unix: socketPath,
      socket: {
        open(socket) {
          socket.write(`${line}\n`)
        },
        data(_socket, data) {
          response.push(Buffer.from(data))
        },
        close() {
          if (settled) return
          settled = true

          try {
            resolve(JSON.parse(Buffer.concat(response).toString('utf8').trim()) as SocketLineBridgeResponse)
          } catch {
            reject(new Error(invalidResponseError))
          }
        },
        connectError(_socket, error) {
          if (settled) return
          settled = true
          reject(error)
        },
        error(_socket, error) {
          if (settled) return
          settled = true
          reject(error)
        }
      }
    }).catch(error => {
      if (settled) return
      settled = true
      reject(error)
    })
  })
  if (decoded.ok) return decoded.result
  throw new Error(decoded.error)
}
