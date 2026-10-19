import { expect, test } from 'bun:test'
import type { Page } from '../content-api'
import { moveDestinations } from './page-location'

function page(id: string, parent_id: string | null = null, extra: Partial<Page> = {}): Page {
  return { id, parent_id, type: 'doc', role: 'edit', title: id, deleted_at: null, ...extra } as Page
}

test('move destinations omit the source, all its descendants, read-only and non-document pages', () => {
  const pages = [
    page('root'),
    page('source', 'root'),
    page('child', 'source'),
    page('grandchild', 'child'),
    page('sibling', 'root'),
    page('readonly', null, { role: 'view' }),
    page('unknown-role', null, { role: undefined }),
    page('database', null, { type: 'database' }),
    page('deleted', null, { deleted_at: '2026-10-18' }),
    page('shared', null, { role: 'manage' })
  ]
  expect(moveDestinations(pages, 'source').map(page => page.id)).toEqual(['root', 'sibling', 'shared'])
})

test('a malformed visible cycle cannot hang the destination picker', () => {
  expect(
    moveDestinations([page('one', 'two'), page('two', 'one'), page('valid')], 'other').map(page => page.id)
  ).toEqual(['valid'])
})
