import type { QueryClient } from '@tanstack/react-query'
import { authenticationRef, podID } from '../common/browser-context'
import { createClientConfig } from '../common/internal-api-client'

import type {
  PodPageType,
  PodPageReadResponse,
  PodPageListData,
  PodPageSearchData,
  PodPageChildrenResponse,
  PodPageSharingWriteData,
  PodPageCreateData,
  PodPageUpdateData,
  PodPageMoveData,
  PodPageUserStateData
} from './api/generated/types.gen'
import {
  podPageList,
  podPageChildren,
  podPageSearch,
  podPageRead,
  podPageCreate,
  podPageUpdate,
  podPageMove,
  podPageDelete,
  podEmbedDelete,
  podPageRestore,
  podPageUserState,
  podPageSharing,
  podPageSharingWrite,
  podDocumentWrite
} from './api/generated/sdk.gen'

export type Page = Omit<PodPageType, 'created_at' | 'updated_at' | 'revision'> &
  Partial<Pick<PodPageType, 'created_at' | 'updated_at' | 'revision'>>
export type PageType = Page['type']
export type PageRole = PodPageReadResponse['role']
export type PageScope = NonNullable<NonNullable<PodPageListData['query']>['scope']>
export type PageSearchOptions = Omit<NonNullable<PodPageSearchData['query']>, 'query'>
export type PageDetail = PodPageReadResponse
export type PageSharing = PodPageSharingWriteData['body']['data']
export type PageMove = NonNullable<PodPageMoveData['body']>['data']

export const contentKeys = {
  get all() {
    return ['pod-content', authenticationRef() ?? '', podID() ?? ''] as const
  },
  get lists() {
    return [...contentKeys.all, 'pages'] as const
  },
  list: (scope: PageScope, query = '') =>
    [...contentKeys.lists, scope, ...(query.trim() ? [query.trim()] : [])] as const,
  children: (scope: 'space' | 'private', parentID?: string) =>
    [...contentKeys.lists, 'children', scope, parentID ?? null] as const,
  search: (query: string, options: PageSearchOptions = {}) =>
    [
      ...contentKeys.lists,
      'search',
      query,
      options.exclude_subtree_of ?? null,
      options.required_action ?? 'page_view'
    ] as const,
  page: (id: string) => [...contentKeys.all, 'page', id] as const,
  sharing: (id: string) => [...contentKeys.all, 'sharing', id] as const
}

/** Applets may issue dynamic Pod requests; product-owned endpoints use the generated SDK below. */
const transport = createClientConfig({}).fetch!
export async function podRequest<T>(path: string, method = 'GET', body?: unknown, signal?: AbortSignal): Promise<T> {
  const multipart = body instanceof FormData
  const response = await transport(`/api/v2/pod${path}`, {
    method,
    credentials: 'same-origin',
    signal,
    headers: {
      accept: 'application/vnd.api+json',
      ...(!multipart && body !== undefined ? { 'content-type': 'application/vnd.api+json' } : {})
    },
    body: body === undefined ? undefined : multipart ? body : JSON.stringify({ data: body })
  })
  const payload = response.status === 204 ? undefined : await response.json()
  return payload as T
}

const pagePath = (id: string) => `/pages/${encodeURIComponent(id)}`
export const pageAPI = {
  list: (scope: PageScope, query = '', signal?: AbortSignal) =>
    podPageList({ query: { scope, query: query.trim() || undefined }, signal }),
  children: (scope: 'space' | 'private', parentID?: string, cursor?: string, signal?: AbortSignal) =>
    podPageChildren({
      query: { ...(parentID ? { parent_id: parentID } : { scope }), ...(cursor ? { cursor } : {}), limit: 200 },
      signal
    }),
  search: (query: string, options: PageSearchOptions = {}, signal?: AbortSignal) =>
    podPageSearch({ query: { ...options, query: query.trim() }, signal }),
  read: (id: string, signal?: AbortSignal) => podPageRead({ path: { id }, signal }),
  create: (body: NonNullable<PodPageCreateData['body']>['data']) => podPageCreate({ body: { data: body } }),
  update: (id: string, body: NonNullable<PodPageUpdateData['body']>['data']) =>
    podPageUpdate({ path: { id }, body: { data: body } }),
  move: (id: string, body: PageMove) => podPageMove({ path: { id }, body: { data: body } }),
  remove: (id: string) => podPageDelete({ path: { id } }),
  removeEmbed: (id: string, ref: string) => podEmbedDelete({ path: { id, ref } }),
  restore: (id: string) => podPageRestore({ path: { id } }),
  write: (id: string, base_revision: number, xml: string) =>
    podDocumentWrite({ path: { id }, body: { data: { base_revision, xml } } }),
  state: (id: string, body: NonNullable<PodPageUserStateData['body']>['data']) =>
    podPageUserState({ path: { id }, body: { data: body } }),
  sharing: (id: string) => podPageSharing({ path: { id } }),
  share: (id: string, body: PageSharing) => podPageSharingWrite({ path: { id }, body: { data: body } })
}

export const pagesQuery = (scope: PageScope, query = '') => ({
  queryKey: contentKeys.list(scope, query),
  queryFn: ({ signal }: { signal: AbortSignal }) => pageAPI.list(scope, query, signal)
})
export const pageSearchQuery = (query: string, options: PageSearchOptions = {}) => ({
  queryKey: contentKeys.search(query.trim(), options),
  queryFn: ({ signal }: { signal: AbortSignal }) => pageAPI.search(query, options, signal)
})
export const pageChildrenQuery = (scope: 'space' | 'private', parentID?: string) => ({
  queryKey: contentKeys.children(scope, parentID),
  initialPageParam: undefined as string | undefined,
  queryFn: ({ pageParam, signal }: { pageParam: string | undefined; signal: AbortSignal }) =>
    pageAPI.children(scope, parentID, pageParam, signal),
  getNextPageParam: (last: PodPageChildrenResponse) => last.next_cursor ?? undefined
})

export const pageQuery = (id: string) => ({
  queryKey: contentKeys.page(id),
  queryFn: ({ signal }: { signal: AbortSignal }) => pageAPI.read(id, signal),
  retry: false
})

export function cachedPages(client: QueryClient): Page[] {
  const pages = new Map<string, Page>()
  for (const [, data] of client.getQueriesData<{ pages: Page[] | { pages: Page[] }[] }>({
    queryKey: contentKeys.lists
  })) {
    for (const item of data?.pages ?? []) {
      for (const page of 'pages' in item ? item.pages : [item]) pages.set(page.id, page)
    }
  }
  return [...pages.values()]
}

export function fileURL(id: string, path: string, sha256?: string): string {
  const params = new URLSearchParams({ path, ...(sha256 ? { sha256 } : {}), ...identityQuery() })
  return `/api/v2/pod${pagePath(id)}/files/content?${params}`
}

export function identityQuery(): Record<string, string> {
  const authentication = authenticationRef()
  return authentication ? { authentication_ref: authentication } : {}
}
