import { WorkerClient } from './api-client/worker-client'
import type { SendTerminalParams, StartTerminalParams, TerminalCapture, TerminalInfo, TerminalStatus } from './types'

/** Agent workplace terminals backed by tmux on the resolved worker. */
export class TerminalManager {
  constructor(private readonly worker: WorkerClient) {}

  /** Lists the named terminals (tmux sessions) currently alive on the worker. */
  list(opts: { signal?: AbortSignal } = {}): Promise<TerminalInfo[]> {
    return this.worker.listTerminals(opts.signal)
  }

  /**
   * Ensures a named terminal exists, creating it if absent. Naming a terminal makes
   * it long-lived and reattachable: a later call with the same name reuses the same
   * tmux session (the returned status distinguishes `started` from `exists`), which
   * is what lets an agent come back to an interactive program across turns.
   */
  start(name: string, params: StartTerminalParams = {}, opts: { signal?: AbortSignal } = {}): Promise<TerminalStatus> {
    return this.worker.startTerminal(name, params, opts.signal)
  }

  /** Types into a terminal: literal `input`, named `keys`, and/or a trailing Enter. */
  send(name: string, params: SendTerminalParams = {}, opts: { signal?: AbortSignal } = {}): Promise<TerminalStatus> {
    return this.worker.sendTerminal(name, params, opts.signal)
  }

  /**
   * Snapshots the terminal's current visible screen (tmux capture-pane). This is a
   * rendered screen view — what a human would see — not the raw byte stream, which
   * is what makes it usable for full-screen TUIs. `lines` bounds the scrollback read.
   */
  capture(
    name: string,
    params: { lines?: number } = {},
    opts: { signal?: AbortSignal } = {}
  ): Promise<TerminalCapture> {
    return this.worker.captureTerminal(name, params.lines, opts.signal)
  }

  /** Kills the terminal (its tmux session) and the program running in it. */
  kill(name: string, opts: { signal?: AbortSignal } = {}): Promise<TerminalStatus> {
    return this.worker.killTerminal(name, opts.signal)
  }
}
