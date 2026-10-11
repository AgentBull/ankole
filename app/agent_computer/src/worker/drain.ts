/** Work load that the Worker reports in its heartbeat and capacity messages. */
export type WorkerLoad = {
  /** Tracked Turn, Job, and control-plane RPC tasks that are still running. */
  activeTasks: number
  /** Milliseconds since the last task ended; zero while a task runs. */
  idleForMs: number
}

/**
 * Tracks process shutdown without confusing it with a failed active turn.
 *
 * Draining stops new turn admission but keeps the RuntimeFabric receive loop
 * alive while tracked tasks wait for control-plane RPC acknowledgements. The
 * same task set is the load that the control plane reads to release an idle
 * Worker.
 */
export class WorkerDrainState {
  private shutdownReason?: string
  private activeTasks = new Set<Promise<unknown>>()
  private idleSince = performance.now()

  get reason(): string | undefined {
    return this.shutdownReason
  }

  get acceptsTurns(): boolean {
    return this.shutdownReason === undefined
  }

  get activeTaskCount(): number {
    return this.activeTasks.size
  }

  get shouldContinue(): boolean {
    return this.acceptsTurns || this.activeTasks.size > 0
  }

  get load(): WorkerLoad {
    const activeTasks = this.activeTasks.size
    return { activeTasks, idleForMs: activeTasks > 0 ? 0 : Math.floor(performance.now() - this.idleSince) }
  }

  begin(reason: string): boolean {
    if (this.shutdownReason !== undefined) return false
    this.shutdownReason = reason
    return true
  }

  /**
   * Adds a task to drain accounting without consuming its result.
   * The detached chain suppresses only its own rejection; callers keep the
   * original Promise.
   */
  track<T>(task: Promise<T>): Promise<T> {
    this.activeTasks.add(task)
    void task
      .finally(() => {
        this.activeTasks.delete(task)
        if (this.activeTasks.size === 0) this.idleSince = performance.now()
      })
      .catch(() => undefined)
    return task
  }
}
