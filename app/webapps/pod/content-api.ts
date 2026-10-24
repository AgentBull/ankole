import { authenticationRef, podID } from '../common/browser-context'
import { createClientConfig } from '../common/internal-api-client'

import type {
  PodPageType,
  PodPageReadResponse,
  PodPageListData,
  PodPageSharingWriteData,
  PodPageCreateData,
  PodPageUpdateData,
  PodPageMoveData,
  PodPageUserStateData
} from './api/generated/types.gen'
import {
  podPageList,
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

export type Page = PodPageType
export type PageType = Page['type']
export type PageRole = PodPageReadResponse['role']
export type PageScope = NonNullable<NonNullable<PodPageListData['query']>['scope']>
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
  list: (scope: PageScope, query = '') => [...contentKeys.lists, scope, query] as const,
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
    podPageList({ query: { scope, ...(query ? { query } : {}) }, signal }),
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
export const pageQuery = (id: string) => ({
  queryKey: contentKeys.page(id),
  queryFn: ({ signal }: { signal: AbortSignal }) => pageAPI.read(id, signal),
  retry: false
})

export function fileURL(id: string, path: string, sha256?: string): string {
  const params = new URLSearchParams({ path, ...(sha256 ? { sha256 } : {}), ...identityQuery() })
  return `/api/v2/pod${pagePath(id)}/files/content?${params}`
}

export function identityQuery(): Record<string, string> {
  const authentication = authenticationRef()
  return authentication ? { authentication_ref: authentication } : {}
}
