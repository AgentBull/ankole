import { useQuery, useQueryClient, type QueryCacheNotifyEvent } from '@tanstack/react-query'
import { lazy, Suspense, useEffect, useMemo, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { InternalAPIError } from '../common/internal-api-client'
import { podPageRouteID } from '../common/pod-url'
import { ContentProvider } from './content-context'
import { pageQuery, type PageDetail } from './content-api'
import { ContentSkeleton } from './content-primitives'
import { windowEmbedBridge, type EmbedBridge } from './embed-bridge'

const BasePage = lazy(() => import('./base-page').then(module => ({ default: module.BasePage })))

/** Reads the Page ID from `/embed/pages/:id`. */
export function embeddedPageID(pathname: string): string | undefined {
  const match = /^\/embed\/pages\/([^/]+)\/?$/.exec(pathname)
  if (!match?.[1]) return
  try {
    return podPageRouteID(decodeURIComponent(match[1]))
  } catch {
    return
  }
}

/** The shell answers 401 when the browser has no Pod session; the app then never calls a Pod API. */
function signedIn(doc: Document = document): boolean {
  return doc.querySelector('meta[name="ankole-response-status"]')?.getAttribute('content') !== '401'
}

/**
 * One Base Page with its tables, views, and filters, and without the Pod sidebar or top bar.
 *
 * The app reports its state to the framing page through the embed bridge. A missing session never
 * navigates the frame to sign-in; the bridge reports `unauthenticated`, and the host page decides.
 */
export function BaseEmbedApp({
  pathname = window.location.pathname,
  bridge: given
}: {
  pathname?: string
  bridge?: EmbedBridge
}) {
  const bridge = useMemo(() => given ?? windowEmbedBridge(), [given])
  const pageID = embeddedPageID(pathname)
  if (!signedIn()) return <EmbedStatus kind="unauthenticated" bridge={bridge} />
  if (!pageID) return <EmbedStatus kind="forbidden" bridge={bridge} />
  return (
    <ContentProvider>
      <EmbeddedBase pageID={pageID} bridge={bridge} />
    </ContentProvider>
  )
}

function EmbeddedBase({ pageID, bridge }: { pageID: string; bridge: EmbedBridge }) {
  const client = useQueryClient()
  const page = useQuery(pageQuery(pageID))
  const root = useRef<HTMLDivElement>(null)
  const [ended, setEnded] = useState(false)

  // A session that ends while the table is open shows up as a 401 on any Pod request.
  useEffect(
    () =>
      client.getQueryCache().subscribe((event: QueryCacheNotifyEvent) => {
        if (event.type !== 'updated' || event.action.type !== 'error') return
        if (event.action.error instanceof InternalAPIError && event.action.error.status === 401) setEnded(true)
      }),
    [bridge, client]
  )

  const detail: PageDetail | undefined = page.data
  const isBase = detail?.page.type === 'base' && !detail.page.deleted_at
  const failed = page.isError || (detail !== undefined && !isBase)
  const unauthenticated = ended || (page.error instanceof InternalAPIError && page.error.status === 401)

  useEffect(() => {
    if (!isBase || !root.current) return
    bridge.post({ type: 'loaded', pageID })
    const element = root.current
    const report = () => bridge.post({ type: 'height', height: Math.ceil(element.scrollHeight) })
    report()
    const observer = new ResizeObserver(report)
    observer.observe(element)
    return () => observer.disconnect()
  }, [bridge, isBase, pageID])

  if (unauthenticated) return <EmbedStatus kind="unauthenticated" bridge={bridge} />
  if (failed) return <EmbedStatus kind="forbidden" pageID={pageID} bridge={bridge} />
  if (!detail) return <ContentSkeleton variant="table" />
  return (
    <div ref={root} className="pod-base-embed min-h-0">
      <Suspense fallback={<ContentSkeleton variant="table" />}>
        <BasePage detail={detail} />
      </Suspense>
    </div>
  )
}

function EmbedStatus({
  kind,
  pageID,
  bridge
}: {
  kind: 'unauthenticated' | 'forbidden'
  pageID?: string
  bridge: EmbedBridge
}) {
  const { t } = useTranslation()
  useEffect(() => {
    bridge.post(kind === 'unauthenticated' ? { type: 'unauthenticated' } : { type: 'forbidden', pageID })
  }, [bridge, kind, pageID])
  return (
    <p role="status" className="text-muted-foreground p-6 text-sm">
      {kind === 'unauthenticated' ? t('pod.content.embed_signed_out') : t('pod.content.embed_unavailable')}
    </p>
  )
}
