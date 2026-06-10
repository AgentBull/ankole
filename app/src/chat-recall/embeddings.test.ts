import { describe, expect, it } from 'bun:test'
import { loadTestEnvFiles } from '@/common/tests/load-test-env'

await loadTestEnvFiles()

const { runChatRecallEmbeddingCycle } = await import('./embeddings')

describe('runChatRecallEmbeddingCycle', () => {
  it('preserves the single-batch behavior when concurrency is 1', async () => {
    const calls: string[] = []
    const result = await runChatRecallEmbeddingCycle(profile(1), 5, {
      enqueuePendingEmbeddings: async () => {
        calls.push('enqueue')
      },
      runClaimedEmbeddingBatch: async () => {
        calls.push('claim')
        return { claimed: 2, synced: 2 }
      }
    })

    expect(calls).toEqual(['enqueue', 'claim'])
    expect(result).toEqual({ claimed: 2, synced: 2 })
  })

  it('enqueues once and runs up to profile concurrency claimed batches', async () => {
    let enqueueCalls = 0
    let claimCalls = 0
    const result = await runChatRecallEmbeddingCycle(profile(3), 5, {
      enqueuePendingEmbeddings: async () => {
        enqueueCalls += 1
      },
      runClaimedEmbeddingBatch: async () => {
        claimCalls += 1
        return { claimed: claimCalls, synced: 1 }
      }
    })

    expect(enqueueCalls).toBe(1)
    expect(claimCalls).toBe(3)
    expect(result).toEqual({ claimed: 6, synced: 3 })
  })
})

function profile(concurrency: number) {
  return {
    providerKind: 'openai',
    providerId: 'test-provider',
    model: 'text-embedding-test',
    batchSize: 8,
    concurrency,
    indexStrategy: 'exact_only',
    profileId: 'test-profile'
  } as any
}
