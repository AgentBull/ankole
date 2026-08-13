import { describe, expect, test } from 'bun:test'
import {
  BrainMetadataEditorModel,
  type BrainOwnerOption,
  agentOwnerUID,
  brainAuditSelectionAfterRestore,
  brainAuditSelectionForScope,
  brainAuditSelectionScope,
  buildMetadataOperations,
  defaultBrainOwnerUID,
  normalizeAliases,
  parsePropertyDrafts,
  propertiesToDrafts,
  setBrainFilter
} from './brain-editor-model'

describe('Brain editor model', () => {
  test('keeps unsaved metadata during same-entry refetch and resets for another entry', () => {
    const model = new BrainMetadataEditorModel()

    model.initialize('entry:alpha', {
      name: 'Alpha',
      type: 'topic',
      summary: 'Original summary',
      aliases: ['Original'],
      propertyDrafts: [{ key: 'stage', value: '"original"' }]
    })
    expect(model.dirty.value).toBe(false)
    model.name.value = 'Unsaved Alpha'
    model.summary.value = 'Unsaved summary'
    model.aliases.value = ['Unsaved']
    model.propertyDrafts.value = [{ key: 'stage', value: '"unsaved"' }]
    expect(model.dirty.value).toBe(true)

    model.initialize('entry:alpha', {
      name: 'Refetched Alpha',
      type: 'person',
      summary: 'Refetched summary',
      aliases: ['Refetched'],
      propertyDrafts: [{ key: 'stage', value: '"refetched"' }]
    })

    expect(model.name.value).toBe('Unsaved Alpha')
    expect(model.type.value).toBe('topic')
    expect(model.summary.value).toBe('Unsaved summary')
    expect(model.aliases.value).toEqual(['Unsaved'])
    expect(model.propertyDrafts.value).toEqual([{ key: 'stage', value: '"unsaved"' }])

    model.initialize('entry:beta', {
      name: 'Beta',
      type: 'project',
      summary: 'Beta summary',
      aliases: ['Beta'],
      propertyDrafts: [{ key: 'stage', value: '"current"' }]
    })

    expect(model.name.value).toBe('Beta')
    expect(model.type.value).toBe('project')
    expect(model.summary.value).toBe('Beta summary')
    expect(model.aliases.value).toEqual(['Beta'])
    expect(model.propertyDrafts.value).toEqual([{ key: 'stage', value: '"current"' }])
    expect(model.dirty.value).toBe(false)
    model[Symbol.dispose]()
  })

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

  test('keeps a requested owner only when it is a listed agent', () => {
    const agents: BrainOwnerOption[] = [
      { uid: 'agent-one', type: 'agent' },
      { uid: 'agent-two', type: 'agent' }
    ]
    expect(agentOwnerUID('agent-two', agents)).toBe('agent-two')
    expect(agentOwnerUID('human-one', agents)).toBe('agent-one')
    expect(agentOwnerUID(null, agents)).toBe('agent-one')
    expect(agentOwnerUID('agent-one', [])).toBe('')
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
    const params = new URLSearchParams('owner=human-one&store=shared&q=policy&cursor=page-two&cursor_history=~')
    const next = setBrainFilter(params, 'owner', 'agent-two')

    expect(next.toString()).toBe('owner=agent-two&store=shared&q=policy')
  })

  test('binds audit selections to the owner and filters but not the cursor page', () => {
    const firstPage = brainAuditSelectionScope(
      'agent-one',
      new URLSearchParams('owner=agent-one&store=self&action=edit_block&cursor=page-one')
    )
    const nextPage = brainAuditSelectionScope(
      'agent-one',
      new URLSearchParams('owner=agent-one&store=self&action=edit_block&cursor=page-two')
    )
    const anotherOwner = brainAuditSelectionScope(
      'agent-two',
      new URLSearchParams('owner=agent-two&store=self&action=edit_block&cursor=page-one')
    )
    const anotherFilter = brainAuditSelectionScope(
      'agent-one',
      new URLSearchParams('owner=agent-one&store=shared&action=edit_block&cursor=page-one')
    )
    const selection = { scope: firstPage, ids: new Set(['audit-one']), confirming: true }

    expect(nextPage).toBe(firstPage)
    expect(brainAuditSelectionForScope(selection, nextPage)).toBe(selection)

    const ownerChanged = brainAuditSelectionForScope(selection, anotherOwner)
    expect([...ownerChanged.ids]).toEqual([])
    expect(ownerChanged.confirming).toBe(false)
    expect([...brainAuditSelectionForScope(ownerChanged, firstPage).ids]).toEqual([])

    const nextOwnerSelection = { ...ownerChanged, ids: new Set(['audit-two']), confirming: true }
    expect(brainAuditSelectionAfterRestore(nextOwnerSelection, selection)).toBe(nextOwnerSelection)

    const returnedOwnerSelection = {
      ...brainAuditSelectionForScope(ownerChanged, firstPage),
      ids: new Set(['audit-three']),
      confirming: true
    }
    expect(brainAuditSelectionAfterRestore(returnedOwnerSelection, selection)).toBe(returnedOwnerSelection)

    const restoredSelection = brainAuditSelectionAfterRestore(selection, selection)
    expect([...restoredSelection.ids]).toEqual([])
    expect(restoredSelection.confirming).toBe(false)

    const filterChanged = brainAuditSelectionForScope(selection, anotherFilter)
    expect([...filterChanged.ids]).toEqual([])
    expect(filterChanged.confirming).toBe(false)
  })
})
