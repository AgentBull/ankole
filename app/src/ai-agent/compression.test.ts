import { describe, expect, it } from 'bun:test'
import { loadTestEnvFiles } from '@/common/tests/load-test-env'

await loadTestEnvFiles()
const { stripCompactionScratch } = await import('./compression')

describe('stripCompactionScratch', () => {
  it('removes scratch analysis blocks without touching summaries that do not contain one', () => {
    expect(
      stripCompactionScratch('<analysis>\nchronological scratch notes\n</analysis>\n\n1. Primary Request: do X')
    ).toBe('1. Primary Request: do X')
    expect(stripCompactionScratch('<ANALYSIS>x</ANALYSIS>\nsummary')).toBe('summary')
    expect(stripCompactionScratch('1. Primary Request: do X')).toBe('1. Primary Request: do X')
  })
})
