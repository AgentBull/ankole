import { WorkerClient } from './api-client/worker-client'
import type { SendTerminalParams, StartTerminalParams, TerminalCapture, TerminalInfo, TerminalStatus } from './types'

/** Agent workplace terminals backed by tmux on the resolved worker. */
export class TerminalManager {
  constructor(private readonly worker: WorkerClient) {}

  list(opts: { signal?: AbortSignal } = {}): Promise<TerminalInfo[]> {
    return this.worker.listTerminals(opts.signal)
  }

  start(name: string, params: StartTerminalParams = {}, opts: { signal?: AbortSignal } = {}): Promise<TerminalStatus> {
    return this.worker.startTerminal(name, params, opts.signal)
  }

  send(name: string, params: SendTerminalParams = {}, opts: { signal?: AbortSignal } = {}): Promise<TerminalStatus> {
    return this.worker.sendTerminal(name, params, opts.signal)
  }

  capture(
    name: string,
    params: { lines?: number } = {},
    opts: { signal?: AbortSignal } = {}
  ): Promise<TerminalCapture> {
    return this.worker.captureTerminal(name, params.lines, opts.signal)
  }

  kill(name: string, opts: { signal?: AbortSignal } = {}): Promise<TerminalStatus> {
    return this.worker.killTerminal(name, opts.signal)
  }
}
