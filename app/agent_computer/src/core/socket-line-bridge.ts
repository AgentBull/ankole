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

// Shared across run bridges: closing a socket does not cancel its accepted RPC.
const MAX_ACTIVE_REQUESTS = 64
const REQUEST_READ_TIMEOUT_MS = 10_000
let activeRequests = 0

export type SocketLineBridge = {
  socketPath: string
  close: () => void
}

type SocketState = {
  buffer: Buffer
  handled: boolean
  admitted: boolean
  released: boolean
  closed: boolean
  stopped: boolean
  handling: boolean
  readTimer?: ReturnType<typeof setTimeout>
  response?: Buffer
}

export function startSocketLineBridge(opts: {
  socketPath: string
  maxRequestBytes: number
  oversizeError: string
  handleLine: (line: string) => Promise<unknown>
}): SocketLineBridge {
  let closed = false
  const sockets = new Set<Bun.Socket<SocketState>>()
  const listener = Bun.listen<SocketState>({
    unix: opts.socketPath,
    socket: {
      open(socket) {
        socket.data = {
          buffer: Buffer.alloc(0),
          handled: false,
          admitted: false,
          released: false,
          closed: false,
          stopped: false,
          handling: false
        }
        sockets.add(socket)
        if (closed || activeRequests >= MAX_ACTIVE_REQUESTS) {
          rejectRequest(socket, 'CLI bridge is busy; request was not accepted')
          return
        }
        socket.data.admitted = true
        activeRequests += 1
        socket.data.readTimer = setTimeout(() => {
          rejectRequest(socket, 'CLI bridge request read timed out; request was not accepted')
        }, REQUEST_READ_TIMEOUT_MS)
        socket.data.readTimer.unref()
      },
      data(socket, data) {
        if (closed || socket.data.closed || socket.data.handled) return

        if (socket.data.buffer.byteLength + data.byteLength > opts.maxRequestBytes) {
          rejectRequest(socket, opts.oversizeError)
          return
        }
        socket.data.buffer = Buffer.concat([socket.data.buffer, data])

        const newline = socket.data.buffer.indexOf(0x0a)
        if (newline < 0) return

        socket.data.handled = true
        clearReadTimer(socket.data)
        const line = socket.data.buffer.subarray(0, newline).toString('utf8')
        socket.data.buffer = Buffer.alloc(0)
        socket.data.handling = true

        void (async () => {
          try {
            writeResponse(socket, await opts.handleLine(line))
          } catch (error) {
            writeResponse(socket, { ok: false, error: errorMessage(error) })
          } finally {
            socket.data.handling = false
            releaseRequest(socket.data)
          }
        })()
      },
      drain: flushResponse,
      close(socket) {
        socket.data.closed = true
        clearReadTimer(socket.data)
        socket.data.buffer = Buffer.alloc(0)
        socket.data.response = undefined
        sockets.delete(socket)
        releaseRequest(socket.data)
      },
      error(socket, _error) {
        // The caller receives a closed socket. RuntimeFabric and domain errors
        // are returned through the normal response path above.
        socket.terminate()
      }
    }
  })

  chmodSync(opts.socketPath, 0o600)
  chownAgentPathSync(opts.socketPath)
  return {
    socketPath: opts.socketPath,
    close: () => {
      if (closed) return
      closed = true
      for (const socket of sockets) {
        socket.data.stopped = true
        clearReadTimer(socket.data)
        socket.data.buffer = Buffer.alloc(0)
        socket.data.response = undefined
      }
      listener.stop(true)
      if (existsSync(opts.socketPath)) unlinkSync(opts.socketPath)
    }
  }
}

function clearReadTimer(state: SocketState): void {
  clearTimeout(state.readTimer)
  state.readTimer = undefined
}

function releaseRequest(state: SocketState): void {
  if (!state.admitted || state.released || !state.closed || state.handling) return
  state.released = true
  activeRequests -= 1
}

function rejectRequest(socket: Bun.Socket<SocketState>, error: string): void {
  socket.data.handled = true
  clearReadTimer(socket.data)
  socket.data.buffer = Buffer.alloc(0)
  writeResponse(socket, { ok: false, error })
}

function writeResponse(socket: Bun.Socket<SocketState>, response: unknown): void {
  if (socket.data.closed || socket.data.stopped) return
  socket.data.response = Buffer.from(`${JSON.stringify(response)}\n`)
  flushResponse(socket)
}

function flushResponse(socket: Bun.Socket<SocketState>): void {
  if (socket.data.closed || socket.data.stopped) return
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
