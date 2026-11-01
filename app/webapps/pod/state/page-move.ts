import type { PageMove as PodPageMove } from '../content-api'
import type { Page } from '../content-api'
import { moveDestinations } from './page-location'

export type TreeOperation = 'before' | 'after' | 'inside'
export type DropAvailability = 'available' | 'blocked' | 'not-available'

export function canMovePage(page: Pick<Page, 'actions'>): boolean {
  return page.actions?.some(action => action === 'node_edit' || action === 'node_manage') === true
}

/** Sibling order is the server's `C` collation order with the ID as tie-breaker. */
export function positionOrder(
  a: Pick<Page, 'position' | 'id' | 'name' | 'title'>,
  b: Pick<Page, 'position' | 'id' | 'name' | 'title'>
): number {
  if (a.position == null && b.position != null) return 1
  if (b.position == null && a.position != null) return -1
  if (a.position != null && b.position != null && a.position !== b.position) return a.position < b.position ? -1 : 1
  const aName = a.name ?? a.title
  const bName = b.name ?? b.title
  const left = Array.from(aName, character => character.codePointAt(0)!)
  const right = Array.from(bName, character => character.codePointAt(0)!)
  for (let index = 0; index < Math.min(left.length, right.length); index++) {
    if (left[index] !== right[index]) return left[index]! - right[index]!
  }
  if (left.length !== right.length) return left.length - right.length
  return a.id < b.id ? -1 : a.id === b.id ? 0 : 1
}

/** The move request for a drop next to or into `target`. */
export function dropRequest(target: Page, operation: TreeOperation): PodPageMove {
  if (operation === 'inside') return { parent_id: target.id, private_owner_uid: null }
  return {
    ...placeOf(target),
    ...(operation === 'before' ? { before_id: target.id } : { after_id: target.id })
  }
}

/** The move request for a drop on the Space or Private root. The page goes last. */
export function rootRequest(root: 'space' | 'private', privateOwner: string | undefined): PodPageMove {
  return { parent_id: null, private_owner_uid: root === 'private' ? (privateOwner ?? null) : null }
}

/**
 * Whether `source` can go next to or into `target`. A drop into its own subtree is blocked.
 * The server still decides access; this only stops drops that cannot succeed.
 */
export function dropAvailability(
  pages: Page[],
  source: Page | undefined,
  target: Page,
  operation: TreeOperation
): DropAvailability {
  if (!source || !canMovePage(source)) return 'not-available'
  const destinations = new Set(moveDestinations(pages, source.id).map(page => page.id))
  if (operation === 'inside') return destinations.has(target.id) ? 'available' : 'blocked'
  if (within(pages, target, source.id)) return 'blocked'
  const parent = target.parent_id ? pages.find(page => page.id === target.parent_id) : undefined
  return !parent || destinations.has(parent.id) ? 'available' : 'blocked'
}

/** The request that moves `page` one place up or down among its siblings, or `null` at an end. */
export function stepRequest(pages: Page[], page: Page, direction: -1 | 1): PodPageMove | null {
  const ordered = siblings(pages, page)
  const index = ordered.findIndex(sibling => sibling.id === page.id)
  if (index < 0) return null
  const neighbor = ordered[index + direction]
  if (!neighbor) return null
  return { ...placeOf(page), ...(direction < 0 ? { before_id: neighbor.id } : { after_id: neighbor.id }) }
}

function placeOf(page: Page): PodPageMove {
  return { parent_id: page.parent_id, private_owner_uid: page.parent_id ? null : page.private_owner_uid }
}

function siblings(pages: Page[], page: Page): Page[] {
  return pages
    .filter(
      candidate =>
        !candidate.deleted_at &&
        candidate.parent_id === page.parent_id &&
        (page.parent_id || candidate.private_owner_uid === page.private_owner_uid)
    )
    .sort(positionOrder)
}

function within(pages: Page[], page: Page, ancestorID: string): boolean {
  const byID = new Map(pages.map(candidate => [candidate.id, candidate]))
  const visited = new Set<string>()
  for (let current: Page | undefined = page; current; current = byID.get(current.parent_id ?? '')) {
    if (current.id === ancestorID) return true
    if (visited.has(current.id)) return false
    visited.add(current.id)
  }
  return false
}
