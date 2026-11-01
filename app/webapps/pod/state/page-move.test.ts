import { expect, test } from 'bun:test'
import type { Page } from '../content-api'
import { canMovePage, positionOrder, dropAvailability, dropRequest, rootRequest, stepRequest } from './page-move'

function page(id: string, actions: Page['actions'], values: Partial<Page> = {}): Page {
  return {
    id,
    title: id,
    type: 'doc',
    actions,
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

const root = page('R', ['node_view', 'node_edit'])
const a = page('A', ['node_view', 'node_edit'], { parent_id: 'R', position: 'A' })
const b = page('B', ['node_view', 'node_edit'], { parent_id: 'R', position: 'B' })
const c = page('C', ['node_view', 'node_edit'], { parent_id: 'R', position: 'C' })
const nested = page('N', ['node_view', 'node_edit'], { parent_id: 'A' })
const table = page('T', ['node_view', 'node_edit'], { parent_id: 'R', type: 'base', position: 'D' })
const readOnly = page('V', ['node_view'], { role: 'view', position: 'V' })
const mine = page('P', ['node_view', 'node_edit'], { private_owner_uid: 'me', position: 'P' })
const pages = [root, a, b, c, nested, table, readOnly, mine]

test('a path node outside the loaded siblings cannot skip unloaded pages with a step move', () => {
  expect(stepRequest([a, b], c, -1)).toBeNull()
  expect(stepRequest([a, b], c, 1)).toBeNull()
  expect(stepRequest([a, b, c], c, -1)).toEqual({ parent_id: 'R', private_owner_uid: null, before_id: 'B' })
})

test('a drop names the sibling next to the page, and an inside drop names the new parent', () => {
  expect(dropRequest(b, 'before')).toEqual({ parent_id: 'R', private_owner_uid: null, before_id: 'B' })
  expect(dropRequest(b, 'after')).toEqual({ parent_id: 'R', private_owner_uid: null, after_id: 'B' })
  expect(dropRequest(b, 'inside')).toEqual({ parent_id: 'B', private_owner_uid: null })
  expect(dropRequest(mine, 'after')).toEqual({ parent_id: null, private_owner_uid: 'me', after_id: 'P' })
  expect(rootRequest('private', 'me')).toEqual({ parent_id: null, private_owner_uid: 'me' })
  expect(rootRequest('space', 'me')).toEqual({ parent_id: null, private_owner_uid: null })
})

test('a page can move into any editable page type but cannot enter its subtree or move without edit access', () => {
  expect(dropAvailability(pages, a, nested, 'inside')).toBe('blocked')
  expect(dropAvailability(pages, a, nested, 'before')).toBe('blocked')
  expect(dropAvailability(pages, root, b, 'after')).toBe('blocked')
  expect(dropAvailability(pages, b, table, 'inside')).toBe('available')
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

test('management can move a source without granting edit access to a destination', () => {
  const manager = page('M', ['node_view', 'node_manage'], { role: 'manage' })
  expect(canMovePage(manager)).toBe(true)
  expect(dropAvailability([...pages, manager], manager, a, 'inside')).toBe('available')
  expect(dropAvailability([...pages, manager], a, manager, 'inside')).toBe('blocked')
  expect(canMovePage(page('unknown', undefined, { role: 'manage' }))).toBe(false)
})

test('folder destinations use contribute, file leaves reject children, and unsorted names use C ordering', () => {
  const folder = page('folder', ['node_view', 'node_contribute'], { type: 'folder' })
  const file = page('file', ['node_view', 'node_edit'], { type: 'file' })
  expect(dropAvailability([...pages, folder, file], a, folder, 'inside')).toBe('available')
  expect(dropAvailability([...pages, folder, file], a, file, 'inside')).toBe('blocked')
  const unordered = [
    page('emoji', [], { position: null, name: '😀' }),
    page('bmp', [], { position: null, name: '\uE000' }),
    page('ascii', [], { position: null, name: 'A' }),
    page('explicit', [], { position: 'V', name: 'Z' })
  ]
  expect(unordered.sort(positionOrder).map(page => page.id)).toEqual(['explicit', 'ascii', 'bmp', 'emoji'])
})
