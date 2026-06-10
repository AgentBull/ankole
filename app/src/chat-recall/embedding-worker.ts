import { logger } from '@/common/logger'
import { runChatRecallEmbeddingCycle } from './embeddings'
import { ensureVectorIndex, getChatRecallStatus } from './readiness'

type WorkerControlMessage = {
  type?: string
}

const workerScope = globalThis as typeof globalThis & {
  close?: () => void
  postMessage?: (message: unknown) => void
  onmessage?: (event: MessageEvent<WorkerControlMessage>) => void
}

let stopped = false

workerScope.onmessage = event => {
  if (event.data?.type === 'stop') stopped = true
}

void loop().catch(error => {
  const message = error instanceof Error ? error.message : String(error)
  workerScope.postMessage?.({ type: 'error', error: message })
  logger.error({ error }, 'Chat recall embedding worker crashed')
})

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
