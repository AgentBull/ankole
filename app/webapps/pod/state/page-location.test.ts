import { expect, test } from 'bun:test'
import type { Page } from '../content-api'
import { canChangePageStructure, canCreateChild, moveDestinations, pageDomain, pageLocation } from './page-location'

function page(id: string, actions: Page['actions'], parent_id: string | null = null, extra: Partial<Page> = {}): Page {
  return {
    id,
    name: id,
    parent_id,
    actions,
    type: 'doc',
    title: id,
    position: id,
    icon: null,
    private_owner_uid: null,
    inherit_permissions: true,
    metadata: {},
    revision: 0,
    saved_from_message_id: null,
    deleted_at: null,
    purge_started_at: null,
    ...extra
  }
}

test('move destinations omit the source, all its descendants, read-only pages', () => {
  const pages = [
    page('root', ['node_view', 'node_edit']),
    page('source', ['node_view', 'node_edit'], 'root'),
    page('child', ['node_view', 'node_edit'], 'source'),
    page('grandchild', ['node_view', 'node_edit'], 'child'),
    page('sibling', ['node_view', 'node_edit'], 'root'),
    page('readonly', ['node_view']),
    page('unknown-actions', undefined, null, { role: 'manage' }),
    page('base', ['node_view', 'node_edit'], null, { type: 'base' }),
    page('deleted', ['node_view', 'node_edit'], null, { deleted_at: '2026-10-18' }),
    page('shared', ['node_view', 'node_edit']),
    page('manage-without-edit', ['node_view', 'node_manage'], null, { role: 'manage' })
  ]
  expect(moveDestinations(pages, 'source').map(page => page.id)).toEqual(['root', 'sibling', 'base', 'shared'])
})

test('a malformed visible cycle cannot hang the destination picker', () => {
  expect(
    moveDestinations(
      [page('one', ['node_edit'], 'two'), page('two', ['node_edit'], 'one'), page('valid', ['node_edit'])],
      'other'
    ).map(page => page.id)
  ).toEqual(['valid'])
})

test('Brain objects, file attachments and ontology containers keep their own destinations', () => {
  const root = page('brain', ['node_view'], null, { type: 'knowledge', system_key: 'ankole_brain' })
  const category = page('notes', ['node_edit'], root.id, {
    type: 'knowledge',
    system_key: 'ankole_brain_category:notes'
  })
  const note = page('note', ['node_edit'], category.id, { type: 'knowledge' })
  const attachment = page('attachment', ['node_edit'], note.id, { type: 'file' })
  expect(pageLocation(root)).toBe('/meta/brain')
  expect(pageLocation(category)).toBe('/meta/brain?category=notes')
  expect(pageLocation(note)).toBe('/meta/brain/note')
  expect(pageDomain(attachment, [root, category, note])).toBe('brain')
  expect(pageLocation(attachment, [root, category, note])).toBe('/meta/brain/attachment')
  expect(canCreateChild(root)).toBe(false)
  expect(canCreateChild(category)).toBe(true)
  expect(canCreateChild(attachment)).toBe(false)
  expect(
    canChangePageStructure(
      page('agent', ['node_manage'], category.id, {
        type: 'knowledge',
        metadata: { entity_type: 'agent', subtype: 'internal' }
      })
    )
  ).toBe(false)
})
