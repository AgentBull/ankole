import { eq, inArray } from '@tanstack/db'
import { useLiveQuery } from '@tanstack/react-db'
import { QueryClientContext, useQueryClient, type QueryClient } from '@tanstack/react-query'
import { useLocation } from '@tanstack/react-router'
import { useCallback, useContext, useEffect, useSyncExternalStore } from 'react'
import {
  hasPageTransliteration,
  isPageSlugReady,
  podPagePath,
  podPagePathnameID,
  resolvePodPagePath,
  subscribePageTransliteration
} from '../common/pod-url'
import { cachedPages, contentKeys, type PageDetail } from './content-api'
import { pageLocation, pageAncestors } from './state/page-location'
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

export function usePageTransliteration(): boolean {
  return useSyncExternalStore(subscribePageTransliteration, hasPageTransliteration, hasPageTransliteration)
}

export function knownPageTitle(client: QueryClient, id: string): string | undefined {
  return (
    pageMetadata(client).collection.get(id)?.title ?? client.getQueryData<PageDetail>(contentKeys.page(id))?.page.title
  )
}

export function pageHrefFor(client: QueryClient | undefined, id: string, title?: string | null): string {
  const detail = client?.getQueryData<PageDetail>(contentKeys.page(id))
  const pages = client ? cachedPages(client) : []
  const page = detail?.page ?? pages.find(page => page.id === id)
  if (page) {
    return pageLocation(
      { ...page, title: title ?? page.title },
      detail?.ancestors ?? pageAncestors(page, new Map(pages.map(page => [page.id, page])))
    )
  }
  return podPagePath(id, title ?? (client ? knownPageTitle(client, id) : undefined))
}

export function usePageHref(): (id: string, title?: string | null) => string {
  const client = useContext(QueryClientContext)
  const transliterationReady = usePageTransliteration()
  return useCallback(
    (id: string, title?: string | null) => {
      void transliterationReady
      return pageHrefFor(client, id, title)
    },
    [client, transliterationReady]
  )
}

export function useResolvePageHref(): (id: string, title?: string | null) => Promise<string> {
  const client = useContext(QueryClientContext)
  return useCallback(
    async (id: string, title?: string | null) => {
      const href = pageHrefFor(client, id, title)
      return href.startsWith('/meta/')
        ? href
        : resolvePodPagePath(id, title ?? (client ? knownPageTitle(client, id) : undefined))
    },
    [client]
  )
}

export function useCanonicalPageUrl(pageID: string, title: string): void {
  const pageHref = usePageHref()
  const transliterationReady = usePageTransliteration()
  const publicHref = useLocation({ select: location => location.publicHref })
  const canonicalPath = pageHref(pageID, title)
  const slugReady = isPageSlugReady(title, transliterationReady)
  useEffect(() => {
    if (!slugReady) return
    const currentPath = window.location.pathname
    if (currentPath === canonicalPath || podPagePathnameID(currentPath) !== pageID) return
    window.history.replaceState(
      window.history.state,
      '',
      `${canonicalPath}${window.location.search}${window.location.hash}`
    )
  }, [canonicalPath, pageID, publicHref, slugReady])
}
