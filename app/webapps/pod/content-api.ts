import { authenticationRef, podID } from '../common/browser-context'
import { createClientConfig } from '../common/internal-api-client'

import type { PodPage, PodPageDetail, PodPageListData, PodSharingWrite } from '../common/api/generated/types.gen'
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
} from '../common/api/generated/sdk.gen'

export type Page = PodPage
export type PageType = Page['type']
export type PageRole = PodPageDetail['role']
export type PageScope = NonNullable<NonNullable<PodPageListData['query']>['scope']>
export type PageDetail = PodPageDetail
export type PageSharing = PodSharingWrite

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
  const response = await transport(`/.internal-apis/pod${path}`, {
    method,
    credentials: 'same-origin',
    signal,
    headers: {
      accept: 'application/json',
      ...(!multipart && body !== undefined ? { 'content-type': 'application/json' } : {})
    },
    body: body === undefined ? undefined : multipart ? body : JSON.stringify(body)
  })
  const payload = response.status === 204 ? undefined : await response.json()
  return payload as T
}

const pagePath = (id: string) => `/pages/${encodeURIComponent(id)}`
export const pageAPI = {
  list: (scope: PageScope, query = '', signal?: AbortSignal) =>
    podPageList({ query: { scope, ...(query ? { query } : {}) }, signal }),
  read: (id: string, signal?: AbortSignal) => podPageRead({ path: { id }, signal }),
  create: (body: Parameters<typeof podPageCreate>[0]['body']) => podPageCreate({ body }),
  update: (id: string, body: Parameters<typeof podPageUpdate>[0]['body']) => podPageUpdate({ path: { id }, body }),
  move: (id: string, body: Parameters<typeof podPageMove>[0]['body']) => podPageMove({ path: { id }, body }),
  remove: (id: string) => podPageDelete({ path: { id } }),
  removeEmbed: (id: string, ref: string) => podEmbedDelete({ path: { id, ref } }),
  restore: (id: string) => podPageRestore({ path: { id } }),
  write: (id: string, base_revision: number, xml: string) =>
    podDocumentWrite({ path: { id }, body: { base_revision, xml } }),
  state: (id: string, body: Parameters<typeof podPageUserState>[0]['body']) => podPageUserState({ path: { id }, body }),
  sharing: (id: string) => podPageSharing({ path: { id } }),
  share: (id: string, body: PageSharing) => podPageSharingWrite({ path: { id }, body })
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
  return `/.internal-apis/pod${pagePath(id)}/files/content?${params}`
}

export function identityQuery(): Record<string, string> {
  const authentication = authenticationRef()
  return authentication ? { authentication_ref: authentication } : {}
}
