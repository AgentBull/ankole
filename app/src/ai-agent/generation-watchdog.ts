import { ms } from '@pleisto/active-support'

export type GenerationStallPhase = 'awaiting_content' | 'streaming'

export interface GenerationStallWatchdogOptions {
  /** Silence budget while waiting for a call's first content chunk (or during tool execution). */
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

const MAX_CHECK_INTERVAL_MS = ms('5s')

/**
 * Stream-health monitor for one generation run, two-phase:
 *
 * - `awaiting_content` — between a call starting and its first content chunk,
 *   and during tool execution. Hidden-CoT models may legitimately stay silent
 *   here for a long time, so the budget is sized by reasoning effort (see
 *   `defaultGenerationStallTimeoutMs`).
 * - `streaming` — the current call has produced content chunks. Providers emit
 *   them at token cadence (including reasoning deltas), so sustained silence
 *   now means the connection died mid-stream; the tighter `streamGapTimeoutMs`
 *   applies.
 *
 * Both wedge modes observed in production go silent instead of erroring (the
 * SDK request timeout only covers time-to-response-headers). The watchdog turns
 * silence beyond the active budget into an abort, which the runtime answers
 * with an automatic retry. This signal is deliberately kept away from the lease
 * heartbeat, which tracks process liveness instead.
 */
export class GenerationStallWatchdog {
  private lastEventAt = 0
  private phase: GenerationStallPhase = 'awaiting_content'
  private timer: ReturnType<typeof setInterval> | null = null
  private stalled = false

  constructor(private readonly options: GenerationStallWatchdogOptions) {}

  start(): void {
    if (this.timer || this.stalled) return
    this.lastEventAt = this.now()
    const interval =
      this.options.checkIntervalMs ??
      Math.min(MAX_CHECK_INTERVAL_MS, this.options.stallTimeoutMs / 4, this.activeGapBudget() / 4)
    this.timer = setInterval(() => this.check(), Math.max(1, interval))
    this.timer.unref?.()
  }

  /** A boundary event (call started, turn ended, tool activity): back to the generous budget. */
  touch(): void {
    if (this.stalled) return
    this.lastEventAt = this.now()
    this.phase = 'awaiting_content'
  }

  /** A content chunk of the current call: the stream is talking, hold it to the tight gap budget. */
  touchContent(): void {
    if (this.stalled) return
    this.lastEventAt = this.now()
    this.phase = 'streaming'
  }

  /** Time since the last agent event — the operator's wedged-vs-working signal. */
  silentForMs(): number {
    return this.lastEventAt === 0 ? 0 : this.now() - this.lastEventAt
  }

  stop(): void {
    if (!this.timer) return
    clearInterval(this.timer)
    this.timer = null
  }

  private activeGapBudget(): number {
    return this.phase === 'streaming'
      ? (this.options.streamGapTimeoutMs ?? this.options.stallTimeoutMs)
      : this.options.stallTimeoutMs
  }

  private check(): void {
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
