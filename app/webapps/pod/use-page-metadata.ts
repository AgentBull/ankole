import { eq, inArray } from '@tanstack/db'
import { useLiveQuery } from '@tanstack/react-db'
import { useQueryClient } from '@tanstack/react-query'
import { pageMetadata, type PageMetadata } from './state/page-metadata'

type PageDisplay = { id: string; title?: string | null; icon?: string | null }

function merge<P extends PageDisplay>(page: P, metadata: PageMetadata | undefined): P {
  if (!metadata) return page
  const title = metadata.title ?? page.title
  const icon = metadata.icon === undefined ? page.icon : metadata.icon
  return title === page.title && icon === page.icon ? page : { ...page, title, icon }
}

export function usePageMetadata<P extends PageDisplay>(page: P): P
export function usePageMetadata<P extends PageDisplay>(page: P | undefined): P | undefined
export function usePageMetadata<P extends PageDisplay>(page: P | undefined): P | undefined {
  const { collection } = pageMetadata(useQueryClient())
  const { data } = useLiveQuery({
    query: q =>
      page
        ? q
            .from({ page: collection })
            .where(({ page: row }) => eq(row.id, page.id))
            .findOne()
        : undefined
  })
  return page ? merge(page, data) : page
}

/** Small result sets (paths and pickers) subscribe only to the IDs they display. */
export function usePagesMetadata<P extends PageDisplay>(pages: readonly P[]): P[] {
  const { collection } = pageMetadata(useQueryClient())
  const ids = pages.map(page => page.id)
  const { data } = useLiveQuery({
    query: q => (ids.length ? q.from({ page: collection }).where(({ page }) => inArray(page.id, ids)) : undefined)
  })
  const byID = new Map((data ?? []).map(page => [page.id, page]))
  return pages.map(page => merge(page, byID.get(page.id)))
}
