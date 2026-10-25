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
    page('root', ['page_view', 'page_edit']),
    page('source', ['page_view', 'page_edit'], 'root'),
    page('child', ['page_view', 'page_edit'], 'source'),
    page('grandchild', ['page_view', 'page_edit'], 'child'),
    page('sibling', ['page_view', 'page_edit'], 'root'),
    page('readonly', ['page_view']),
    page('unknown-actions', undefined, null, { role: 'manage' }),
    page('database', ['page_view', 'page_edit'], null, { type: 'database' }),
    page('deleted', ['page_view', 'page_edit'], null, { deleted_at: '2026-10-18' }),
    page('shared', ['page_view', 'page_edit']),
    page('manage-without-edit', ['page_view', 'page_manage'], null, { role: 'manage' })
  ]
  expect(moveDestinations(pages, 'source').map(page => page.id)).toEqual(['root', 'sibling', 'database', 'shared'])
})

test('a malformed visible cycle cannot hang the destination picker', () => {
  expect(
    moveDestinations(
      [page('one', ['page_edit'], 'two'), page('two', ['page_edit'], 'one'), page('valid', ['page_edit'])],
      'other'
    ).map(page => page.id)
  ).toEqual(['valid'])
})
