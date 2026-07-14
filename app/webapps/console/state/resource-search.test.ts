import { describe, expect, test } from 'bun:test'
import { matchesResourceSearch } from './resource-search'

describe('matchesResourceSearch', () => {
  test('matches any visible resource value without case sensitivity', () => {
    expect(matchesResourceSearch('research', 'deep-researcher', 'Research Analyst', 'active')).toBe(true)
    expect(matchesResourceSearch('ACTIVE', 'deep-researcher', 'Research Analyst', 'active')).toBe(true)
  })

  test('treats a blank query as no filter', () => {
    expect(matchesResourceSearch('  ', undefined)).toBe(true)
  })
})
