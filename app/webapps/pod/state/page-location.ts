import type { Page } from '../content-api'

export function pageAncestors(page: Page, byID: ReadonlyMap<string, Page>): Page[] {
  const visited = new Set([page.id])
  const ancestors: Page[] = []
  let parent = page.parent_id ? byID.get(page.parent_id) : undefined
  while (parent && !visited.has(parent.id)) {
    visited.add(parent.id)
    ancestors.unshift(parent)
    parent = parent.parent_id ? byID.get(parent.parent_id) : undefined
  }
  return ancestors
}

export function canCreateChild(page: Pick<Page, 'type' | 'actions' | 'is_root'>): boolean {
  if (page.type === 'file') return false
  const action = page.type === 'folder' && !page.is_root ? 'node_contribute' : 'node_edit'
  return page.actions?.includes(action) === true
}

/** Filters the loaded tree. Remote move searches exclude the full subtree on the server. */
export function moveDestinations(pages: Page[], sourceID: string): Page[] {
  const byID = new Map(pages.map(page => [page.id, page]))
  return pages.filter(page => {
    if (!canCreateChild(page) || page.deleted_at) return false
    const visited = new Set<string>()
    let ancestor: Page | undefined = page
    while (ancestor) {
      if (ancestor.id === sourceID || visited.has(ancestor.id)) return false
      visited.add(ancestor.id)
      ancestor = ancestor.parent_id ? byID.get(ancestor.parent_id) : undefined
    }
    return true
  })
}
