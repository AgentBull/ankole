import { describe, expect, test } from 'bun:test'
import { effectiveResourceSearchQuery, matchesResourceSearch } from './resource-search'

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
