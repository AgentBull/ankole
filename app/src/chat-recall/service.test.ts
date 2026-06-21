// Tests the recall search service's pure orchestration: BM25 query
// normalization and the degrade-vs-unavailable behavior of the multi-route
// search. The database, embedding provider, reranker, and clock are all faked
// through injected dependencies, so nothing here touches PostgreSQL or a provider.
import { describe, expect, it } from 'bun:test'
import { loadTestEnvFiles } from '@/common/tests/load-test-env'

await loadTestEnvFiles()

// Imported dynamically after env is loaded because the module graph reads config
// at import time; a static import would evaluate before loadTestEnvFiles runs.
const { formatChatHistorySearchResult, normalizeChatRecallBm25Query, searchChatHistoryWithDependencies } =
  await import('./service')

const embeddingProfile = {
  providerKind: 'openai',
  providerId: 'test-provider',
  model: 'text-embedding-test',
  batchSize: 8,
  concurrency: 1,
  indexStrategy: 'exact_only',
  profileId: 'test-profile'
}

const enabledStatus = {
  enabled: true,
  disabledReasons: [],
  embeddingProfile,
  config: {
    rerank: {
      limit: 10,
      rrfK: 60,
      recencyHalfLifeDays: 30,
      mmrLambda: 0.78
    }
  }
}

const baseInput = {
  agentUid: 'agent-1',
  query: 'AgentBull',
  requesterPrincipalUid: 'human-1'
}

describe('normalizeChatRecallBm25Query', () => {
  // Each case is a real failure mode: a stray pg_search operator that would parse-
  // error (`(`, `:`, `"`, `*`), CJK that must survive tokenization, and a filename
  // whose `.`/`?` split into separate terms. `*` alone has no word token, so null.
  it('keeps CJK and identifier tokens while stripping pg_search syntax characters', () => {
    expect(normalizeChatRecallBm25Query('(AgentBull')).toBe('AgentBull')
    expect(normalizeChatRecallBm25Query('AgentBull:测试')).toBe('AgentBull 测试')
    expect(normalizeChatRecallBm25Query('"unterminated')).toBe('unterminated')
    expect(normalizeChatRecallBm25Query('*')).toBeNull()
    expect(normalizeChatRecallBm25Query('煜马数据')).toBe('煜马数据')
    expect(normalizeChatRecallBm25Query('image_cleanup.png?')).toBe('image_cleanup png')
  })
})

describe('searchChatHistoryWithDependencies', () => {
  // The degrade contract: one route failing still yields available results from the
  // other, with the failure recorded in degradedReasons.
  it('returns vector-only results when BM25 search fails', async () => {
    const result = await runSearch({
      searchBm25: async () => {
        throw new Error('pg_search parse error')
      },
      searchVector: async () => [candidate('vector-doc', 'vector')]
    })

    expect(result.available).toBe(true)
    expect(result.degradedReasons).toEqual(['bm25 search failed: pg_search parse error'])
    expect(result.results).toHaveLength(1)
    expect(result.results[0]?.routeRanks).toEqual({ vector: 1 })
    expect(formatChatHistorySearchResult(result)).toContain('Chat history recall degraded:')
  })

  it('returns BM25-only results when vector search fails', async () => {
    const result = await runSearch({
      searchBm25: async () => [candidate('bm25-doc', 'bm25')],
      searchVector: async () => {
        throw new Error('embedding provider unavailable')
      }
    })

    expect(result.available).toBe(true)
    expect(result.degradedReasons).toEqual(['vector search failed: embedding provider unavailable'])
    expect(result.results).toHaveLength(1)
    expect(result.results[0]?.routeRanks).toEqual({ bm25: 1 })
  })

  // Only when every attempted route fails does the result flip to unavailable.
  it('returns unavailable when every attempted search route fails', async () => {
    const result = await runSearch({
      searchBm25: async () => {
        throw new Error('pg_search parse error')
      },
      searchVector: async () => {
        throw new Error('embedding provider unavailable')
      }
    })

    expect(result.available).toBe(false)
    expect(result.results).toEqual([])
    expect(result.unavailableReasons).toEqual([
      'bm25 search failed: pg_search parse error',
      'vector search failed: embedding provider unavailable'
    ])
  })

  // A query that normalizes to null (here `*`) must not even call the BM25 route;
  // the bm25Calls counter proves the route was skipped, not just emptied.
  it('skips BM25 when normalization produces no searchable token', async () => {
    let bm25Calls = 0
    const result = await runSearch(
      {
        searchBm25: async () => {
          bm25Calls += 1
          return []
        },
        searchVector: async () => []
      },
      { query: '*' }
    )

    expect(bm25Calls).toBe(0)
    expect(result.available).toBe(true)
    expect(result.results).toEqual([])
  })
})

// Drives the service with a fully faked dependency set. The fake rerank stands in
// for the native addon: it just truncates candidates to the limit and assigns
// descending scores, which is enough to exercise the orchestration without the
// real ranking logic. Per-test overrides replace individual collaborators.
async function runSearch(dependencyOverrides: Record<string, unknown>, inputOverrides: Partial<typeof baseInput> = {}) {
  return searchChatHistoryWithDependencies(
    {
      ...baseInput,
      ...inputOverrides
    },
    {
      getStatus: async () => enabledStatus,
      loadMessageWindow: async (_roomId: string, messageId: string) => [
        {
          authorId: 'user-ext',
          isAnchor: true,
          messageId,
          sentAt: new Date('2026-06-10T00:00:00.000Z'),
          text: `message ${messageId}`
        }
      ],
      nowMs: () => Date.parse('2026-06-10T00:00:00.000Z'),
      rerank: (snapshot: any) => ({
        results: snapshot.candidates.slice(0, snapshot.limit).map((item: any, index: number) => ({
          id: item.id,
          score: 1 - index / 10,
          scoreBreakdown: {}
        }))
      }),
      resolveRequesterPrincipalUid: async () => undefined,
      searchBm25: async () => [],
      searchVector: async () => [],
      ...dependencyOverrides
    } as any
  )
}

function candidate(documentId: string, route: 'bm25' | 'vector') {
  return {
    authorId: 'user-ext',
    documentId,
    hasAttachments: false,
    hasLinks: false,
    isDm: true,
    mentionedAgent: false,
    messageId: documentId,
    metadata: {},
    rank: 1,
    roomId: 'room-1',
    route,
    score: 0.9,
    searchText: `search text for ${documentId}`,
    sentAt: new Date('2026-06-10T00:00:00.000Z')
  }
}
