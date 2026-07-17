import { chmod, mkdir, rm } from 'node:fs/promises'
import { createServer, type Server, type Socket } from 'node:net'
import { dirname } from 'node:path'
import { BrowserDataError, browserError } from '../errors'
import {
  failureResponse,
  parseBrowserRequest,
  successResponse,
  type BrowserRequest,
  type BrowserResponse
} from '../protocol'
import { SessionManager } from './session-manager'

const MaxRequestBytes = 8 * 1024 * 1024

export class BrowserDaemonServer {
  private readonly manager: SessionManager
  private readonly sockets = new Set<Socket>()
  private server?: Server

  constructor(
    readonly socketPath: string,
    maxActiveBrowsers = 4
  ) {
    this.manager = new SessionManager(maxActiveBrowsers)
  }

  async listen(): Promise<void> {
    await mkdir(dirname(this.socketPath), { recursive: true })
    await rm(this.socketPath, { force: true })
    const server = createServer(socket => this.accept(socket))
    this.server = server
    await new Promise<void>((resolve, reject) => {
      server.once('error', reject)
      server.listen(this.socketPath, () => {
        server.removeListener('error', reject)
        resolve()
      })
    })
    await chmod(this.socketPath, 0o660)
  }

  async close(): Promise<void> {
    const server = this.server
    this.server = undefined
    if (server) {
      const closed = new Promise<void>(resolve => server.close(() => resolve()))
      for (const socket of this.sockets) socket.destroy()
      await closed
    }
    await this.manager.close()
    await rm(this.socketPath, { force: true })
  }

  private accept(socket: Socket): void {
    this.sockets.add(socket)
    let buffer = Buffer.alloc(0)
    let handled = false
    const controller = new AbortController()
    socket.once('close', () => {
      this.sockets.delete(socket)
      controller.abort(new DOMException('client disconnected', 'AbortError'))
    })
    socket.on('data', chunk => {
      if (handled) return
      buffer = Buffer.concat([buffer, Buffer.from(chunk)])
      if (buffer.length > MaxRequestBytes) {
        handled = true
        this.respond(
          socket,
          failureResponse({}, browserError(new BrowserDataError('invalid_command', 'request too large')))
        )
        return
      }
      const newline = buffer.indexOf(10)
      if (newline === -1) return
      handled = true
      void this.handleLine(socket, buffer.subarray(0, newline).toString('utf8'), controller.signal)
    })
    socket.once('error', () => controller.abort(new DOMException('client connection failed', 'AbortError')))
  }

  private async handleLine(socket: Socket, line: string, signal: AbortSignal): Promise<void> {
    let request: BrowserRequest | undefined
    let partial: Partial<Pick<BrowserRequest, 'id' | 'route' | 'session'>> = {}
    try {
      const raw = JSON.parse(line) as Record<string, unknown>
      partial = {
        ...(typeof raw.id === 'string' ? { id: raw.id } : {}),
        ...(typeof raw.route === 'string' ? { route: raw.route } : {}),
        ...(typeof raw.session === 'string' ? { session: raw.session } : {})
      }
      request = parseBrowserRequest(raw)
      const result = await this.manager.dispatch(request, signal)
      this.respond(socket, successResponse(request, result.data, result.warnings))
    } catch (error) {
      this.respond(socket, failureResponse(request ?? partial, browserError(error)))
    }
  }

  private respond(socket: Socket, response: BrowserResponse): void {
    if (socket.destroyed) return
    socket.end(`${JSON.stringify(response)}\n`)
  }
}
