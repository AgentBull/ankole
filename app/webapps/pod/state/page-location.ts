import { podPagePath } from '../../common/pod-url'
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

type PageStructure = Pick<Page, 'system_key' | 'is_root' | 'deleted_at' | 'purge_started_at'> &
  Partial<Pick<Page, 'metadata'>>

/** System Pages keep their names and tree positions; content follows the caller's edit permission. */
export function canChangePageStructure(page: PageStructure): boolean {
  if (page.metadata?.subtype === 'internal' && ['person', 'agent'].includes(String(page.metadata.entity_type))) {
    return false
  }
  return page.system_key == null && !page.is_root && !page.deleted_at && !page.purge_started_at
}

export function canRenamePage(page: PageStructure & Pick<Page, 'actions'>): boolean {
  return canChangePageStructure(page) && page.actions?.includes('node_edit') === true
}

export function canTrashPage(page: PageStructure & Pick<Page, 'type' | 'actions'>): boolean {
  return (
    canChangePageStructure(page) && page.actions?.includes(page.type === 'file' ? 'node_edit' : 'node_manage') === true
  )
}

export function canCreateChild(
  page: Pick<Page, 'type' | 'actions' | 'is_root' | 'deleted_at' | 'purge_started_at'> &
    Partial<Pick<Page, 'system_key'>>
): boolean {
  if (['ankole_brain', 'ankole_brain_agents', 'ankole_brain_sources'].includes(page.system_key ?? '')) return false
  if (page.type === 'file' || page.deleted_at || page.purge_started_at) return false
  return page.actions?.includes('node_edit') === true
}

/** Filters the loaded tree. Remote move searches exclude the full subtree on the server. */
export function moveDestinations(pages: readonly Page[], sourceID: string): Page[] {
  const byID = new Map(pages.map(page => [page.id, page]))
  return pages.filter(page => {
    if (!canCreateChild(page)) return false
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

export function pageDomain(
  page: Pick<Page, 'type' | 'system_key'>,
  ancestors: readonly Page[] = []
): 'pages' | 'brain' {
  return page.type === 'knowledge' ||
    page.system_key?.startsWith('ankole_brain') ||
    ancestors.some(parent => parent.type === 'knowledge' || parent.system_key?.startsWith('ankole_brain'))
    ? 'brain'
    : 'pages'
}

export function pageLocation(page: Page, ancestors: readonly Page[] = []): string {
  if (page.system_key === 'ankole_brain') return '/meta/brain'
  if (page.system_key?.startsWith('ankole_brain_category:')) {
    return `/meta/brain?category=${encodeURIComponent(page.name)}`
  }
  if (page.system_key === 'ankole_brain_agents') return '/meta/brain?category=agents'
  if (page.system_key === 'ankole_brain_sources') return '/meta/brain?category=sources'
  return pageDomain(page, ancestors) === 'brain' ? `/meta/brain/${page.id}` : podPagePath(page.id, page.title)
}
