/**
 * Tracks process shutdown without confusing it with a failed active turn.
 *
 * Draining stops new turn admission but keeps the RuntimeFabric receive loop
 * alive while tracked tasks wait for control-plane RPC acknowledgements.
 */
export class WorkerDrainState {
  private shutdownReason?: string
  private activeTasks = new Set<Promise<unknown>>()

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
      })
      .catch(() => undefined)
    return task
  }
}
