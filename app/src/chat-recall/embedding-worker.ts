// Entry point of the dedicated embedding Worker thread. Embedding runs the
// background loop off the main thread so a slow provider call or large batch
// never blocks request handling. The parent runtime (runtime.ts) owns this
// worker's lifecycle and restart policy; this file only runs the loop and
// reports back over postMessage.
import { logger } from '@/common/logger'
import { runChatRecallEmbeddingCycle } from './embeddings'
import { ensureVectorIndex, getChatRecallStatus } from './readiness'

type WorkerControlMessage = {
  type?: string
}

// Bun's Worker global is typed loosely here; this narrows just the handful of
// worker-scope members the loop uses so they are not `any`.
const workerScope = globalThis as typeof globalThis & {
  close?: () => void
  postMessage?: (message: unknown) => void
  onmessage?: (event: MessageEvent<WorkerControlMessage>) => void
}

let stopped = false

// Cooperative stop: the parent posts `{ type: 'stop' }`, and the loop exits at
// the next iteration boundary rather than being hard-terminated mid-batch.
workerScope.onmessage = event => {
  if (event.data?.type === 'stop') stopped = true
}

// A crash escaping the loop is reported to the parent (which restarts with
// backoff) and logged. Without this the thread would die silently and recall
// would stop making progress with no signal.
void loop().catch(error => {
  const message = error instanceof Error ? error.message : String(error)
  workerScope.postMessage?.({ type: 'error', error: message })
  logger.error({ error }, 'Chat recall embedding worker crashed')
})

/**
 * Polls for due embedding work until told to stop.
 *
 * Re-reads status every tick (with `install: false`, so the loop never mutates
 * schema) so that disabling recall or changing the provider/poll interval at
 * runtime takes effect on the next pass without restarting the worker. After each
 * cycle it calls {@link ensureVectorIndex} so an index for a newly-seen dimension
 * gets built once vectors exist. A failed cycle is reported but does not break the
 * loop — the next poll retries — because transient provider errors must not stop
 * the background worker. `Bun.sleep` paces polling; with no work the loop idles at
 * the configured interval instead of spinning.
 */
async function loop(): Promise<void> {
  while (!stopped) {
    const status = await getChatRecallStatus({ install: false })
    const pollIntervalMs = status.config.worker.pollIntervalMs

    if (status.enabled && status.embeddingProfile && status.config.worker.enabled) {
      try {
        const result = await runChatRecallEmbeddingCycle(status.embeddingProfile, status.config.worker.maxAttempts)
        await ensureVectorIndex(status.embeddingProfile)
        workerScope.postMessage?.({ type: 'batch', claimed: result.claimed, synced: result.synced })
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        workerScope.postMessage?.({ type: 'error', error: message })
      }
    }

    await Bun.sleep(pollIntervalMs)
  }

  workerScope.close?.()
}
