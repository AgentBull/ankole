/**
 * Turn-local Unix-socket line bridge for shell CLIs and the automation-job
 * SDK. The random socket path is the only shell-side capability: each
 * connection carries one newline-terminated JSON request and receives one
 * JSON response, so the shell never holds the worker auth key or fabric
 * endpoint.
 *
 * `src/automation-jobs/sdk.ts` keeps its own copy of the client half on
 * purpose — that file runs inside the job sandbox as a self-contained module
 * and cannot import worker code.
 */

import { chmodSync, existsSync, unlinkSync } from 'node:fs'
import { errorMessage } from '../common/errors'

/** Response envelope the CLI bridges write for every request. */
export type SocketLineBridgeResponse = { ok: true; result: Record<string, unknown> } | { ok: false; error: string }

export type SocketLineBridge = {
  socketPath: string
  close: () => void
}

type SocketState = {
  buffer: string
  handled: boolean
}

/**
 * Starts one bridge listener. `handleLine` owns request decoding and RPC
 * dispatch; its resolved value is written back verbatim, and a thrown error
 * becomes `{ ok: false, error }`.
 */
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
        socket.data = { buffer: '', handled: false }
      },
      data(socket, data) {
        if (socket.data.handled) return
        socket.data.buffer += Buffer.from(data).toString('utf8')

        if (Buffer.byteLength(socket.data.buffer, 'utf8') > opts.maxRequestBytes) {
          socket.data.handled = true
          writeResponse(socket, { ok: false, error: opts.oversizeError })
          return
        }

        const newline = socket.data.buffer.indexOf('\n')
        if (newline < 0) return

        socket.data.handled = true
        const line = socket.data.buffer.slice(0, newline)

        void opts
          .handleLine(line)
          .then(response => writeResponse(socket, response))
          .catch(error => writeResponse(socket, { ok: false, error: errorMessage(error) }))
      },
      error(_socket, _error) {
        // The caller receives a closed socket. RuntimeFabric and domain errors
        // are returned through the normal response path above.
      }
    }
  })

  chmodSync(opts.socketPath, 0o600)
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
  socket.write(`${JSON.stringify(response)}\n`)
  socket.end()
}

/**
 * Sends one JSON line to a bridge and returns the parsed JSON response.
 * The bridge answers once and closes, so the response is parsed on close.
 */
export async function requestSocketLineBridge<T>(
  socketPath: string,
  line: string,
  invalidResponseError: string
): Promise<T> {
  return new Promise((resolve, reject) => {
    let response = ''
    let settled = false

    void Bun.connect({
      unix: socketPath,
      socket: {
        open(socket) {
          socket.write(`${line}\n`)
        },
        data(_socket, data) {
          response += Buffer.from(data).toString('utf8')
        },
        close() {
          if (settled) return
          settled = true

          try {
            resolve(JSON.parse(response.trim()) as T)
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
}
