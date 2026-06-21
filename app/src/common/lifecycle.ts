/**
 * Uniform start/stop lifecycle implemented by each subsystem runtime — plugins,
 * identity providers, and the External Gateway. The composition root sequences
 * these in dependency order without depending on any concrete runtime class.
 */
export interface Runtime<TStats = void> {
  /**
   * Brings the subsystem up, resolving only once it is ready to serve. The
   * composition root awaits this before starting the next runtime, so the
   * returned `TStats` (when used) is a safe summary of what came online.
   */
  start(): Promise<TStats>
  /**
   * Drains and shuts the subsystem down. Runtimes are stopped in reverse start
   * order; implementations resolve only once their resources are released so the
   * shutdown sequence stays strictly ordered.
   */
  stop(): Promise<void>
}
