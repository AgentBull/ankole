// Tests the embedding cycle's control flow — enqueue-once then fan out claimed
// batches up to the profile's concurrency, and sum their counts — using injected
// fakes for the two phases so no database or provider is involved.
import { describe, expect, it } from 'bun:test'
import { loadTestEnvFiles } from '@/common/tests/load-test-env'

await loadTestEnvFiles()

// Dynamic import after env load, same reason as the sibling service test.
const { runChatRecallEmbeddingCycle } = await import('./embeddings')

describe('runChatRecallEmbeddingCycle', () => {
  // Concurrency 1 must keep the original order: enqueue once, then a single claim.
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

  // Concurrency 3 must enqueue exactly once and run three claim batches, with the
  // returned counts being the sum across batches (claimed 1+2+3=6, synced 1+1+1=3).
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
