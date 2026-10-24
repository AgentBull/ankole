import { expect, test } from 'bun:test'
import type { Page } from '../content-api'
import { dropAvailability, dropRequest, rootRequest, stepRequest } from './page-move'

function page(id: string, values: Partial<Page> = {}): Page {
  return {
    id,
    title: id,
    type: 'doc',
    role: 'edit',
    parent_id: null,
    private_owner_uid: null,
    position: id,
    icon: null,
    deleted_at: null,
    purge_started_at: null,
    inherit_permissions: true,
    revision: 0,
    saved_from_message_id: null,
    created_at: '',
    updated_at: '',
    ...values
  }
}

const root = page('R')
const a = page('A', { parent_id: 'R', position: 'A' })
const b = page('B', { parent_id: 'R', position: 'B' })
const c = page('C', { parent_id: 'R', position: 'C' })
const nested = page('N', { parent_id: 'A' })
const table = page('T', { parent_id: 'R', type: 'database', position: 'D' })
const readOnly = page('V', { role: 'view', position: 'V' })
const mine = page('P', { private_owner_uid: 'me', position: 'P' })
const pages = [root, a, b, c, nested, table, readOnly, mine]

test('a drop names the sibling next to the page, and an inside drop names the new parent', () => {
  expect(dropRequest(b, 'before')).toEqual({ parent_id: 'R', private_owner_uid: null, before_id: 'B' })
  expect(dropRequest(b, 'after')).toEqual({ parent_id: 'R', private_owner_uid: null, after_id: 'B' })
  expect(dropRequest(b, 'inside')).toEqual({ parent_id: 'B', private_owner_uid: null })
  expect(dropRequest(mine, 'after')).toEqual({ parent_id: null, private_owner_uid: 'me', after_id: 'P' })
  expect(rootRequest('private', 'me')).toEqual({ parent_id: null, private_owner_uid: 'me' })
  expect(rootRequest('space', 'me')).toEqual({ parent_id: null, private_owner_uid: null })
})

test('a page cannot go into its own subtree, into a non-document, or move without edit access', () => {
  expect(dropAvailability(pages, a, nested, 'inside')).toBe('blocked')
  expect(dropAvailability(pages, a, nested, 'before')).toBe('blocked')
  expect(dropAvailability(pages, root, b, 'after')).toBe('blocked')
  expect(dropAvailability(pages, b, table, 'inside')).toBe('not-available')
  expect(dropAvailability(pages, b, table, 'after')).toBe('available')
  expect(dropAvailability(pages, readOnly, b, 'after')).toBe('not-available')
  expect(dropAvailability(pages, b, readOnly, 'inside')).toBe('blocked')
  expect(dropAvailability(pages, c, a, 'before')).toBe('available')
  expect(dropAvailability(pages, c, mine, 'inside')).toBe('available')
})

test('steps stop at the ends of the loaded siblings', () => {
  expect(stepRequest(pages, b, -1)).toEqual({ parent_id: 'R', private_owner_uid: null, before_id: 'A' })
  expect(stepRequest(pages, b, 1)).toEqual({ parent_id: 'R', private_owner_uid: null, after_id: 'C' })
  expect(stepRequest(pages, a, -1)).toBeNull()
  expect(stepRequest(pages, table, 1)).toBeNull()
  expect(stepRequest(pages, mine, -1)).toBeNull()
})
