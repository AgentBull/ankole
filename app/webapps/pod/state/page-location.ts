import type { Page } from '../content-api'

/** Filters the loaded tree. Remote move searches exclude the full subtree on the server. */
export function moveDestinations(pages: Page[], sourceID: string): Page[] {
  const byID = new Map(pages.map(page => [page.id, page]))
  return pages.filter(page => {
    if (!page.actions?.includes('page_edit') || page.deleted_at) return false
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
