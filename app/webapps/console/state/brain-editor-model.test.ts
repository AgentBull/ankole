import { describe, expect, test } from 'bun:test'
import {
  brainCursorPage,
  buildMetadataOperations,
  canReturnBrainCursor,
  nextBrainCursor,
  normalizeAliases,
  parsePropertyDrafts,
  previousBrainCursor,
  propertiesToDrafts,
  setBrainFilter,
  sourceDocumentIDs
} from './brain-editor-model'

describe('Brain editor model', () => {
  test('emits only changed structured metadata operations', () => {
    expect(
      buildMetadataOperations(
        {
          id: 'entry-1',
          summary: 'Old summary',
          aliases: ['Alpha'],
          properties: { stage: 'draft', stale: true },
          lock_version: 4
        },
        {
          summary: 'Current summary',
          aliases: ['Alpha', ' A ', 'Beta'],
          properties: { stage: 'current', score: 3 }
        }
      )
    ).toEqual([
      {
        operation: 'set_summary',
        entry_id: 'entry-1',
        summary: 'Current summary',
        expected_entry_lock_version: 4
      },
      {
        operation: 'set_aliases',
        entry_id: 'entry-1',
        aliases: ['Alpha', 'A', 'Beta'],
        expected_entry_lock_version: 4
      },
      {
        operation: 'set_property',
        entry_id: 'entry-1',
        key: 'stage',
        value: 'current',
        expected_entry_lock_version: 4
      },
      {
        operation: 'set_property',
        entry_id: 'entry-1',
        key: 'stale',
        value: null,
        expected_entry_lock_version: 4
      },
      {
        operation: 'set_property',
        entry_id: 'entry-1',
        key: 'score',
        value: 3,
        expected_entry_lock_version: 4
      }
    ])
  })

  test('round trips structured property drafts and reports malformed JSON', () => {
    const drafts = propertiesToDrafts({ active: true, tags: ['one'] })
    expect(parsePropertyDrafts(drafts)).toEqual({ ok: true, value: { active: true, tags: ['one'] } })
    expect(parsePropertyDrafts([{ key: 'active', value: '{' }])).toMatchObject({ ok: false, key: 'active' })
  })

  test('normalizes aliases and extracts unique source document addresses', () => {
    expect(normalizeAliases([' Alpha ', '', 'Alpha', 'Beta'])).toEqual(['Alpha', 'Beta'])
    expect(
      sourceDocumentIDs(
        'First (src:signal-gateway-entry:abc-123), repeat src:signal-gateway-entry:abc-123 and src:signal-gateway-entry:def_456.'
      )
    ).toEqual(['signal-gateway-entry:abc-123', 'signal-gateway-entry:def_456'])
  })

  test('keeps a stable cursor history for next and previous page navigation', () => {
    const first = new URLSearchParams('owner=agent-one')
    const second = nextBrainCursor(first, 'cursor-two')
    const third = nextBrainCursor(second, 'cursor-three')

    expect(second.get('cursor')).toBe('cursor-two')
    expect(brainCursorPage(second)).toBe(2)
    expect(brainCursorPage(third)).toBe(3)
    expect(canReturnBrainCursor(third)).toBe(true)

    const returnedToSecond = previousBrainCursor(third)
    const returnedToFirst = previousBrainCursor(returnedToSecond)
    expect(returnedToSecond.get('cursor')).toBe('cursor-two')
    expect(returnedToFirst.get('cursor')).toBeNull()
    expect(returnedToFirst.get('cursor_history')).toBeNull()
    expect(canReturnBrainCursor(returnedToFirst)).toBe(false)
  })

  test('changing a filter clears only the matching cursor surface', () => {
    const params = new URLSearchParams(
      'owner=agent-one&cursor=list-page&cursor_history=~&audit_cursor=audit-page&audit_cursor_history=~'
    )
    const list = setBrainFilter(params, 'query', 'Nightjar')
    const audit = setBrainFilter(params, 'action', 'edit_block', 'audit_')

    expect(list.get('query')).toBe('Nightjar')
    expect(list.get('cursor')).toBeNull()
    expect(list.get('cursor_history')).toBeNull()
    expect(list.get('audit_cursor')).toBe('audit-page')

    expect(audit.get('action')).toBe('edit_block')
    expect(audit.get('audit_cursor')).toBeNull()
    expect(audit.get('audit_cursor_history')).toBeNull()
    expect(audit.get('cursor')).toBe('list-page')
  })
})
