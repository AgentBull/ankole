import { expect, test } from 'bun:test'
import type { Page } from '../content-api'
import { moveDestinations } from './page-location'

function page(id: string, actions: Page['actions'], parent_id: string | null = null, extra: Partial<Page> = {}): Page {
  return {
    id,
    parent_id,
    actions,
    type: 'doc',
    title: id,
    position: id,
    icon: null,
    private_owner_uid: null,
    inherit_permissions: true,
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
