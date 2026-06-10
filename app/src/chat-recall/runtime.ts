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

class ChatRecallRuntime {
  private worker?: Worker
  private workerState: ChatRecallWorkerState = 'not_started'
  private workerLastError?: string
  private paused = false
  private restartTimer?: ReturnType<typeof setTimeout>

  async start(): Promise<ChatRecallStatus> {
    const status = await this.status({ install: true })
    if (!status.enabled || !status.config.worker.enabled) {
      this.stopWorker(status.config.worker.enabled ? 'stopped' : 'paused')
      return status
    }

    if (!this.paused) this.ensureWorker()
    return this.status({ install: false })
  }

  async stop(): Promise<void> {
    this.paused = true
    this.stopWorker('stopped')
  }

  async pause(): Promise<ChatRecallStatus> {
    this.paused = true
    this.stopWorker('paused')
    return this.status({ install: true })
  }

  async resume(): Promise<ChatRecallStatus> {
    this.paused = false
    return this.start()
  }

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

  async runOnce(): Promise<{ claimed: number; synced: number }> {
    const status = await this.status({ install: true })
    if (!status.enabled || !status.embeddingProfile) {
      throw new Error(`chat recall is unavailable: ${status.disabledReasons.join('; ')}`)
    }
    const result = await runChatRecallEmbeddingCycle(status.embeddingProfile, status.config.worker.maxAttempts)
    await ensureVectorIndex(status.embeddingProfile)
    return result
  }

  async status(options: { install?: boolean } = {}): Promise<ChatRecallStatus> {
    return getChatRecallStatus({
      install: options.install ?? false,
      runtime: {
        workerState: this.workerState,
        workerLastError: this.workerLastError
      }
    })
  }

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

export const chatRecallRuntime = new ChatRecallRuntime()
