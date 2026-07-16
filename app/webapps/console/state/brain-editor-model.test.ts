import { describe, expect, test } from 'bun:test'
import {
  brainCursorPage,
  buildMetadataOperations,
  canReturnBrainCursor,
  defaultBrainOwnerUID,
  nextBrainCursor,
  normalizeAliases,
  parsePropertyDrafts,
  previousBrainCursor,
  propertiesToDrafts,
  setBrainFilter
} from './brain-editor-model'

describe('Brain editor model', () => {
  test('defaults to an agent owner before falling back to another Principal', () => {
    expect(
      defaultBrainOwnerUID([
        { uid: 'human-one', type: 'human' },
        { uid: 'agent-one', type: 'agent' }
      ])
    ).toBe('agent-one')
    expect(defaultBrainOwnerUID([{ uid: 'human-one', type: 'human' }])).toBe('human-one')
    expect(defaultBrainOwnerUID([])).toBe('')
  })

  test('emits only changed structured metadata operations', () => {
    expect(
      buildMetadataOperations(
        {
          id: 'entry-1',
          name: 'Old name',
          type: 'topic',
          summary: 'Old summary',
          aliases: ['Alpha'],
          properties: { stage: 'draft', stale: true },
          lock_version: 4
        },
        {
          name: 'Current name',
          type: 'policy',
          summary: 'Current summary',
          aliases: ['Alpha', ' A ', 'Beta'],
          properties: { stage: 'current', score: 3 }
        }
      )
    ).toEqual([
      {
        operation: 'set_name',
        entry_id: 'entry-1',
        name: 'Current name',
        expected_entry_lock_version: 4
      },
      {
        operation: 'set_type',
        entry_id: 'entry-1',
        type: 'policy',
        expected_entry_lock_version: 4
      },
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

  test('normalizes aliases', () => {
    expect(normalizeAliases([' Alpha ', '', 'Alpha', 'Beta'])).toEqual(['Alpha', 'Beta'])
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

  test('switching the owner keeps other filters and resets the old owner cursor', () => {
    const params = new URLSearchParams('owner=human-one&store=public&q=policy&cursor=page-two&cursor_history=~')
    const next = setBrainFilter(params, 'owner', 'agent-two')

    expect(next.toString()).toBe('owner=agent-two&store=public&q=policy')
  })
})
