/**
 * Uniform start/stop lifecycle implemented by each subsystem runtime — plugins,
 * identity providers, and the External Gateway. The composition root sequences
 * these in dependency order without depending on any concrete runtime class.
 */
export interface Runtime<TStats = void> {
  start(): Promise<TStats>
  stop(): Promise<void>
}
