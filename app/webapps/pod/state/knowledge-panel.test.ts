import { expect, test } from 'bun:test'
import { parseKnowledgePanel } from './knowledge-panel'

const empty = () => ({ backlinks: [], claims: [], timelines: [], scorecard: { takes: 0, brier: null } })

test('knowledge panels accept nullable fields and open business vocabularies', () => {
  const panel = parseKnowledgePanel({
    ...empty(),
    future: { enabled: true },
    backlinks: [{ page_id: 'page', title: 'Title', link_type: 'new_relationship', context: null }],
    claims: [{ id: 'claim', claim_type: 'new_claim', claim: 'Evidence', confidence: null, context: null, weight: 2 }],
    timelines: [{ id: 'event', date: '2026-11-03', summary: 'A change', provenance: null }]
  })
  expect(panel.backlinks[0]?.link_type).toBe('new_relationship')
  expect(panel.claims[0]?.claim_type).toBe('new_claim')
  expect(panel.scorecard.brier).toBeNull()
})

test('malformed knowledge responses cannot masquerade as an empty panel', () => {
  for (const value of [
    null,
    {},
    { ...empty(), backlinks: null },
    { ...empty(), claims: [{ id: 'claim', claim: 123 }] },
    { ...empty(), scorecard: { takes: 1, brier: '0.5' } }
  ]) {
    expect(() => parseKnowledgePanel(value)).toThrow()
  }
  expect(parseKnowledgePanel(empty())).toEqual(empty())
})
