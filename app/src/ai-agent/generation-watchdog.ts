import { ms } from '@pleisto/active-support'

export type GenerationStallPhase = 'awaiting_content' | 'streaming'

export interface GenerationStallWatchdogOptions {
  /** Silence budget while waiting for a call's first content chunk after its response headers. */
  stallTimeoutMs: number
  /**
   * Silence budget between content chunks once a call has started streaming.
   * Modern providers chunk continuously even through reasoning, so a stream
   * that spoke and then went quiet for minutes is a dead pipe, not a thinking
   * model. Defaults to `stallTimeoutMs` when not set.
   */
  streamGapTimeoutMs?: number
  /** Invoked exactly once when the active budget elapses. */
  onStall: (silentForMs: number, phase: GenerationStallPhase) => void
  /** Test seams. */
  checkIntervalMs?: number
  now?: () => number
}

// Upper bound on how often the silence check runs. The interval is otherwise
// derived from the budget (see `arm`); this cap keeps the timer from firing
// rarely on a very generous budget, so a stall is still noticed within a few
// seconds of the budget elapsing rather than a fraction of it.
const MAX_CHECK_INTERVAL_MS = ms('5s')

/**
 * Stream-health monitor for the LLM API request, and *only* that request.
 *
 * "Stall" means the provider call itself went silent — not that the run is
 * idle. The watchdog is therefore armed only while a call is in flight (`arm()`
 * when the call begins, before the request, so a pre-headers wedge is caught
 * too; `disarm()` when the stream ends). Everything between calls — tool
 * execution above all — is deliberately unwatched: a 20-minute build or a hung
 * worker is the tool layer's problem to bound (its own timeout / transport),
 * never a "generation stall". The previous design counted tool time against
 * this budget and aborted+retried the whole generation when a tool ran long;
 * that conflation is the bug this fixes.
 *
 * While armed, two phases:
 * - `awaiting_content` — the call is in flight but no content chunk has arrived
 *   yet (sending the request, awaiting headers, then the model's first token).
 *   Hidden-CoT models can think a while here, so the budget is the generous
 *   `stallTimeoutMs` (see `defaultGenerationStallTimeoutMs`).
 * - `streaming` — content chunks are flowing. Providers emit them at token
 *   cadence (reasoning included), so sustained silence now means the connection
 *   died mid-stream; the tighter `streamGapTimeoutMs` applies.
 *
 * Both wedge modes go silent rather than erroring (the SDK request timeout only
 * covers time-to-response-headers). The watchdog turns post-header silence into
 * an abort, which the runtime answers with a retry. This signal is kept away
 * from the lease heartbeat, which tracks process liveness instead.
 */
export class GenerationStallWatchdog {
  private lastEventAt = 0
  private phase: GenerationStallPhase = 'awaiting_content'
  private timer: ReturnType<typeof setInterval> | null = null
  private stalled = false
  private armed = false

  constructor(private readonly options: GenerationStallWatchdogOptions) {}

  /**
   * Begin watching an LLM call: it is about to issue its request (turn start).
   * Resets the silence clock and (re)starts the check timer. Called again for
   * each call in the run.
   */
  arm(): void {
    // A watchdog that already fired stays fired: the run is being torn down and
    // re-arming would let a second call resurrect a dead monitor.
    if (this.stalled) return
    this.armed = true
    this.lastEventAt = this.now()
    this.phase = 'awaiting_content'
    // The timer is shared across all calls in a run; later arms just reset the
    // clock above and reuse the running interval.
    if (this.timer) return
    // Sample several times per budget so silence is caught near the budget, not
    // a multiple of it. Capped by MAX_CHECK_INTERVAL_MS for very large budgets.
    const interval =
      this.options.checkIntervalMs ??
      Math.min(MAX_CHECK_INTERVAL_MS, this.options.stallTimeoutMs / 4, this.activeGapBudget() / 4)
    this.timer = setInterval(() => this.check(), Math.max(1, interval))
    // Do not let this background timer keep the process alive on its own.
    this.timer.unref?.()
  }

  /** The LLM stream ended (or errored): stop watching until the next call arms. */
  disarm(): void {
    this.armed = false
  }

  /** A content chunk of the in-flight call: the stream is talking, hold it to the tight gap budget. */
  touchContent(): void {
    if (this.stalled || !this.armed) return
    this.lastEventAt = this.now()
    this.phase = 'streaming'
  }

  /** Whether a provider stream is currently being watched — the operator's "LLM vs tool" signal. */
  isWatchingLlmStream(): boolean {
    return this.armed
  }

  /** Time since the last stream event while armed; 0 when not watching a call (e.g. tool execution). */
  silentForMs(): number {
    if (!this.armed || this.lastEventAt === 0) return 0
    return this.now() - this.lastEventAt
  }

  /** Tears down the check timer for good (run end, or right after a stall fires). Unlike {@link disarm} this also kills the interval, so the watchdog cannot be re-armed for a later call. */
  stop(): void {
    this.armed = false
    if (!this.timer) return
    clearInterval(this.timer)
    this.timer = null
  }

  // The silence budget for the current phase: the tight stream-gap budget once
  // content is flowing, the generous first-token budget while still waiting. The
  // gap budget falls back to the first-token budget when not separately set.
  private activeGapBudget(): number {
    return this.phase === 'streaming'
      ? (this.options.streamGapTimeoutMs ?? this.options.stallTimeoutMs)
      : this.options.stallTimeoutMs
  }

  // One tick of the silence check. Fires `onStall` exactly once: `stalled` latches
  // and the timer is stopped before the callback runs, so a long-running callback
  // (abort + recovery) cannot re-enter or fire twice.
  private check(): void {
    if (!this.armed) return
    const silentForMs = this.now() - this.lastEventAt
    if (silentForMs < this.activeGapBudget()) return
    this.stalled = true
    this.stop()
    this.options.onStall(silentForMs, this.phase)
  }

  private now(): number {
    return this.options.now?.() ?? Date.now()
  }
}
