import { sql } from 'drizzle-orm'
import { ms } from '@pleisto/active-support'
import { DB } from '@/common/database'
import { logger } from '@/common/logger'
import { runChatRecallEmbeddingCycle } from './embeddings'
import {
  ensureChatRecallSchema,
  ensureVectorIndex,
  getChatRecallStatus,
  type ChatRecallStatus,
  type ChatRecallWorkerState
} from './readiness'

// Messages the embedding worker posts back: a completed cycle's counts, or an
// error string from a failed cycle/crash.
type ChatRecallWorkerMessage =
  | {
      type: 'batch'
      claimed: number
      synced: number
    }
  | {
      type: 'error'
      error: string
    }

const RESTART_BACKOFF_MS = ms('30s')

/**
 * Single owner of the embedding worker's lifecycle for this process.
 *
 * Holds the one worker thread and its observable state, and translates operator
 * actions (start/stop/pause/resume/reindex) and worker crashes into spawn,
 * terminate, and backoff-restart decisions. Exposed as a module singleton
 * ({@link chatRecallRuntime}) because there must be at most one embedding worker
 * per process.
 */
class ChatRecallRuntime {
  private worker?: Worker
  private workerState: ChatRecallWorkerState = 'not_started'
  private workerLastError?: string
  // `paused` is the operator's intent to stay stopped. It is checked everywhere a
  // (re)start could happen so that a pause is not undone by an in-flight restart
  // timer or a status refresh.
  private paused = false
  private restartTimer?: ReturnType<typeof setTimeout>

  /**
   * Brings the worker up if recall is ready and enabled, otherwise stops it.
   *
   * The first status call uses `install: true` so this is also the moment that
   * provisions the schema/indexes; the second uses `install: false` to report the
   * resulting state cheaply without provisioning again. When the worker config is
   * disabled it reports `stopped`; when recall is merely unavailable it reports
   * `paused`, distinguishing "operator turned it off" from "not ready yet".
   */
  async start(): Promise<ChatRecallStatus> {
    const status = await this.status({ install: true })
    if (!status.enabled || !status.config.worker.enabled) {
      this.stopWorker(status.config.worker.enabled ? 'stopped' : 'paused')
      return status
    }

    if (!this.paused) this.ensureWorker()
    return this.status({ install: false })
  }

  /** Stops the worker and records the operator's intent to keep it stopped. */
  async stop(): Promise<void> {
    this.paused = true
    this.stopWorker('stopped')
  }

  /** Operator pause: stops the worker but leaves recall configured and ready. */
  async pause(): Promise<ChatRecallStatus> {
    this.paused = true
    this.stopWorker('paused')
    return this.status({ install: true })
  }

  /** Clears the pause flag and starts again. */
  async resume(): Promise<ChatRecallStatus> {
    this.paused = false
    return this.start()
  }

  /**
   * Forces every embedding for the current profile to be rebuilt.
   *
   * Resets all rows of this profile back to `pending` with a cleared attempt
   * count and error, so the worker re-embeds them from scratch. Existing synced
   * vectors stay in place until overwritten, so search keeps working during the
   * rebuild. Clears any pause and starts the worker so the reset rows are actually
   * drained.
   */
  async reindex(): Promise<ChatRecallStatus> {
    const status = await this.status({ install: true })
    if (!status.enabled || !status.embeddingProfile) {
      throw new Error(`chat recall is unavailable: ${status.disabledReasons.join('; ')}`)
    }

    await ensureChatRecallSchema(status.embeddingProfile)
    await DB.execute(sql`
      UPDATE chat_recall_embeddings
      SET status = 'pending',
          attempt_count = 0,
          next_retry_at = now(),
          locked_at = NULL,
          last_error = NULL,
          updated_at = now()
      WHERE profile_id = ${status.embeddingProfile.profileId}
    `)
    this.paused = false
    this.ensureWorker()
    return this.status({ install: false })
  }

  /**
   * Runs exactly one embedding cycle inline, without the background worker.
   *
   * For operator "run now" and tests: it does the same work as one worker tick on
   * the calling thread and returns the counts, so progress can be observed
   * synchronously.
   */
  async runOnce(): Promise<{ claimed: number; synced: number }> {
    const status = await this.status({ install: true })
    if (!status.enabled || !status.embeddingProfile) {
      throw new Error(`chat recall is unavailable: ${status.disabledReasons.join('; ')}`)
    }
    const result = await runChatRecallEmbeddingCycle(status.embeddingProfile, status.config.worker.maxAttempts)
    await ensureVectorIndex(status.embeddingProfile)
    return result
  }

  /** Reports readiness, folding in this runtime's live worker state. */
  async status(options: { install?: boolean } = {}): Promise<ChatRecallStatus> {
    return getChatRecallStatus({
      install: options.install ?? false,
      runtime: {
        workerState: this.workerState,
        workerLastError: this.workerLastError
      }
    })
  }

  /**
   * Spawns the worker thread if one is not already running.
   *
   * Idempotent on purpose — start, resume, and reindex all call it, but the
   * `this.worker` guard keeps that to a single thread. Bails when paused so a
   * restart timer firing after the operator paused cannot revive the worker. Wires
   * both `onerror` (worker crash) and `onmessageerror` (undeserializable message)
   * to stop and schedule a backoff restart, so any worker-side failure self-heals.
   */
  private ensureWorker(): void {
    if (this.paused || this.worker) return

    clearTimeout(this.restartTimer)
    this.restartTimer = undefined
    this.workerState = 'running'
    const worker = new Worker(new URL('./embedding-worker.ts', import.meta.url).href, { type: 'module' })
    this.worker = worker
    worker.onmessage = event => this.handleWorkerMessage(event.data as ChatRecallWorkerMessage)
    worker.onerror = event => {
      this.workerLastError = event.message
      this.stopWorker('failed')
      this.scheduleRestart()
    }
    worker.onmessageerror = event => {
      this.workerLastError = `worker message error: ${String(event.data)}`
      this.stopWorker('failed')
      this.scheduleRestart()
    }
  }

  /**
   * Folds a message from the worker into runtime state.
   *
   * Successful batches are logged only when they actually moved rows, to keep idle
   * polling quiet. An error message is remembered as `workerLastError` (surfaced in
   * status) but is treated as non-fatal here — the worker keeps polling — because
   * a single failed cycle is expected to recover on its own.
   */
  private handleWorkerMessage(message: ChatRecallWorkerMessage): void {
    if (message.type === 'batch') {
      if (message.claimed > 0 || message.synced > 0) {
        logger.debug({ claimed: message.claimed, synced: message.synced }, 'Chat recall embedding batch completed')
      }
      return
    }
    if (message.type === 'error') {
      this.workerLastError = message.error
      logger.warn({ error: message.error }, 'Chat recall worker batch failed')
    }
  }

  /**
   * Tears down the current worker and records the resulting state.
   *
   * Sends a cooperative `stop` first so the worker can finish the in-flight batch
   * cleanly, then `terminate()` as the hard backstop. The `postMessage` is wrapped
   * because the worker may already be dead (the crash path lands here too), and a
   * throw there must not prevent termination or the state update.
   */
  private stopWorker(nextState: ChatRecallWorkerState): void {
    clearTimeout(this.restartTimer)
    this.restartTimer = undefined
    const worker = this.worker
    this.worker = undefined
    if (worker) {
      try {
        worker.postMessage({ type: 'stop' })
      } catch {
        // The worker may already be gone.
      }
      worker.terminate()
    }
    this.workerState = nextState
  }

  /**
   * Schedules a single delayed restart after a worker failure.
   *
   * Guards on `paused` (do not revive a paused worker) and on an existing timer
   * (coalesce repeated failures into one pending restart). The fixed backoff keeps
   * a persistently crashing worker from hot-looping. A restart that itself fails
   * records the error and schedules the next attempt, so retries continue until the
   * underlying problem clears.
   */
  private scheduleRestart(): void {
    if (this.paused || this.restartTimer) return
    this.restartTimer = setTimeout(() => {
      this.restartTimer = undefined
      void this.start().catch(error => {
        this.workerLastError = error instanceof Error ? error.message : String(error)
        this.workerState = 'failed'
        this.scheduleRestart()
      })
    }, RESTART_BACKOFF_MS)
  }
}

/** Process-wide singleton; there must be at most one embedding worker. */
export const chatRecallRuntime = new ChatRecallRuntime()
