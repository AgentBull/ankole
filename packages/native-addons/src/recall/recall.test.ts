import { describe, expect, it } from 'bun:test'
import { recallRerank } from '../../index.js'

const nowMs = Date.parse('2026-06-10T00:00:00.000Z')

function candidate(id: string, overrides: Record<string, unknown> = {}) {
  return {
    id,
    routeRanks: { bm25: 5 },
    sentAtMs: nowMs - 86_400_000,
    text: `message ${id}`,
    dedupeKey: id,
    windowKey: `room-${id}`,
    metadataSignals: {},
    ...overrides
  }
}

describe('recall native rerank', () => {
  it('combines route ranks with vector weighting', () => {
    const result = recallRerank({
      limit: 2,
      nowMs,
      candidates: [
        candidate('bm25-only', { routeRanks: { bm25: 1 } }),
        candidate('vector-first', { routeRanks: { vector: 1 } })
      ]
    })

    expect(result.results.map((item: { id: string }) => item.id)).toEqual(['vector-first', 'bm25-only'])
    expect(result.results[0].scoreBreakdown.rrf).toBeGreaterThan(result.results[1].scoreBreakdown.rrf)
  })

  it('boosts recent and metadata-relevant candidates', () => {
    const result = recallRerank({
      limit: 2,
      nowMs,
      candidates: [
        candidate('old', {
          routeRanks: { bm25: 1 },
          sentAtMs: nowMs - 180 * 86_400_000,
          metadataSignals: {}
        }),
        candidate('current-dm', {
          routeRanks: { bm25: 2 },
          sentAtMs: nowMs - 1_000,
          metadataSignals: {
            sameCurrentRoom: true,
            isDm: true,
            addressedOrMentioned: true,
            authorIsRequester: true
          }
        })
      ]
    })

    expect(result.results[0].id).toBe('current-dm')
    expect(result.results[0].scoreBreakdown.metadataBoost).toBeGreaterThan(0)
    expect(result.results[0].scoreBreakdown.recency).toBeGreaterThan(result.results[1].scoreBreakdown.recency)
  })

  it('uses MMR to reduce near-duplicate windows', () => {
    const result = recallRerank({
      limit: 3,
      nowMs,
      options: { mmrLambda: 0.55 },
      candidates: [
        candidate('a1', { routeRanks: { bm25: 1 }, text: 'alpha beta gamma delta', windowKey: 'room-a' }),
        candidate('a2', { routeRanks: { bm25: 2 }, text: 'alpha beta gamma delta again', windowKey: 'room-a' }),
        candidate('b1', { routeRanks: { bm25: 4 }, text: 'unrelated project notes', windowKey: 'room-b' })
      ]
    })

    expect(result.results[0].id).toBe('a1')
    expect(result.results[1].id).toBe('b1')
    expect(result.results[2].scoreBreakdown.mmrPenalty).toBeGreaterThan(0)
  })

  it('rejects invalid snapshots', () => {
    expect(() => recallRerank({ candidates: [{ routeRanks: {} }] })).toThrow(/invalid recall snapshot/)
  })
})
