import { describe, expect, test } from 'bun:test'
import {
  effectiveResourceSearchQuery,
  matchesResourceSearch,
  RESOURCE_SEARCH_COMMIT_DELAY_MS,
  scheduleResourceSearchCommit
} from './resource-search'

describe('effectiveResourceSearchQuery', () => {
  test('uses the current empty query instead of one stale deferred filter', () => {
    expect(effectiveResourceSearchQuery('', 'no-such-agent')).toBe('')
    expect(effectiveResourceSearchQuery('  ', 'no-such-agent')).toBe('')
  })

  test('keeps non-empty filtering deferred', () => {
    expect(effectiveResourceSearchQuery('new query', 'previous query')).toBe('previous query')
  })
})

describe('matchesResourceSearch', () => {
  test('matches any visible resource value without case sensitivity', () => {
    expect(matchesResourceSearch('research', 'deep-researcher', 'Research Analyst', 'active')).toBe(true)
    expect(matchesResourceSearch('ACTIVE', 'deep-researcher', 'Research Analyst', 'active')).toBe(true)
  })

  test('treats a blank query as no filter', () => {
    expect(matchesResourceSearch('  ', undefined)).toBe(true)
  })
})

describe('scheduleResourceSearchCommit', () => {
  test('commits after 300 ms and cancels an obsolete draft', async () => {
    let commits = 0

    expect(RESOURCE_SEARCH_COMMIT_DELAY_MS).toBe(300)

    const cancel = scheduleResourceSearchCommit(() => {
      commits += 1
    })
    expect(commits).toBe(0)
    cancel()
    await Bun.sleep(RESOURCE_SEARCH_COMMIT_DELAY_MS + 20)
    expect(commits).toBe(0)

    scheduleResourceSearchCommit(() => {
      commits += 1
    })
    await Bun.sleep(RESOURCE_SEARCH_COMMIT_DELAY_MS + 20)
    expect(commits).toBe(1)
  })
})
