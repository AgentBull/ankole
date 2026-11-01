import { pageMetadata } from './state/page-metadata'
import type { InfiniteData, QueryClient } from '@tanstack/react-query'
import { authenticationRef, podID } from '../common/browser-context'
import { createClientConfig } from '../common/internal-api-client'

import type {
  PodPageType,
  PodPageReadResponse,
  PodPageListData,
  PodPageSearchData,
  PodPageChildrenResponse,
  PodPageSharingResponse,
  PodPageSharingUpdateData,
  PodPageSharingWriteData,
  PodPageCreateData,
  PodPageUpdateData,
  PodPageMoveData,
  PodPageUserStateData,
  PodMentionCandidatesData,
  PodMentionCandidatesResponse,
  PodMentionsResolveData,
  PodMentionsResolveResponse
} from './api/generated/types.gen'
import {
  podPageList,
  podPageChildren,
  podPageNavigation,
  podPageSearch,
  podPageRead,
  podPageInsights,
  podPageViewers,
  podPageHistory,
  podPageHistoryEntry,
  podPageHistoryRestore,
  podPageComments,
  podCommentRead,
  podPageCommentSummary,
  podPageCommentsRead,
  podPageCommentCreate,
  podPageCommentUpdate,
  podPageCommentDelete,
  podPageCommentResolve,
  podPageCommentAnchor,
  podPageCreate,
  podPageUpdate,
  podPageMove,
  podPageDelete,
  podEmbedsDelete,
  podPageRestore,
  podPagePurge,
  podPageUserState,
  podPageSharing,
  podPageSharingUpdate,
  podPageSharingWrite,
  podMentionCandidates,
  podMentionsResolve
} from './api/generated/sdk.gen'

export type Page = Omit<PodPageType, 'created_at' | 'updated_at' | 'revision' | 'children_view'> &
  Partial<Pick<PodPageType, 'revision' | 'children_view'>> & {
    created_at?: string | null
    updated_at?: string | null
  }
export type PageType = Page['type']
export type NavigationPage = PodPageChildrenResponse['pages'][number]
export type SubpageItem = PodPageChildrenResponse['pages'][number]
export type ChildrenViewPatch = NonNullable<NonNullable<PodPageUpdateData['body']>['data']>['children_view']
export type PageRole = PodPageReadResponse['role']
export type PageScope = NonNullable<NonNullable<PodPageListData['query']>['scope']>
export type PageSearchOptions = Omit<NonNullable<PodPageSearchData['query']>, 'query'>
export type PageDetail = PodPageReadResponse
export type PageSharingDetail = PodPageSharingResponse
export type PageSharing = PodPageSharingWriteData['body']['data']
export type PageSharingUpdate = NonNullable<PodPageSharingUpdateData['body']>['data']
export type PageMove = NonNullable<PodPageMoveData['body']>['data']
export type MentionCategoryParam = NonNullable<NonNullable<PodMentionCandidatesData['query']>['category']>
export type MentionCandidatesResponse = PodMentionCandidatesResponse
export type MentionsResolveResponse = PodMentionsResolveResponse
export type MentionsResolveInput = NonNullable<PodMentionsResolveData['body']>['data']

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
  subpages: (scope: 'space' | 'private', parentID: string) =>
    [...contentKeys.lists, 'children', scope, parentID, 'details'] as const,
  navigation: () => [...contentKeys.lists, 'navigation'] as const,
  search: (query: string, options: PageSearchOptions = {}) =>
    [
      ...contentKeys.lists,
      'search',
      query,
      options.exclude_subtree_of ?? null,
      options.required_action ?? 'node_view',
      options.embeddable ?? false
    ] as const,
  page: (id: string) => [...contentKeys.all, 'page', id] as const,
  insights: (id: string) => [...contentKeys.all, 'page', id, 'insights'] as const,
  history: (id: string) => [...contentKeys.all, 'page', id, 'history'] as const,
  snapshot: (id: string, snapshotID: string) => [...contentKeys.all, 'page', id, 'history', snapshotID] as const,
  comments: (id: string, status?: string) =>
    [...contentKeys.page(id), 'comments', ...(status ? [status] : [])] as const,
  commentSummary: (id: string) => [...contentKeys.comments(id), 'summary'] as const,
  customEmojis: () => [...contentKeys.all, 'custom-emojis'] as const,
  sharing: (id: string) => [...contentKeys.all, 'sharing', id] as const,
  mentions: () => [...contentKeys.all, 'mentions'] as const,
  mentionCandidates: (category: MentionCategoryParam, query: string, currentPageID?: string) =>
    [...contentKeys.all, 'mentions', 'candidates', category, query.trim(), currentPageID ?? null] as const
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
const pageTitleMaxLength = 255
const graphemes = new Intl.Segmenter(undefined, { granularity: 'grapheme' })

/**
 * The control plane rejects a Page title longer than 255 code points, while an input `maxLength`
 * counts UTF-16 units and can split a character. Like `maxLength`, this function keeps the text
 * around an edit of `previous` and shortens only the inserted text, at a grapheme cluster boundary of
 * the edited title. When no inserted grapheme cluster fits, it keeps `previous`.
 */
export function limitPageTitle(title: string, previous = ''): string {
  const next = [...title]
  if (next.length <= pageTitleMaxLength) return title
  const before = [...previous]
  let start = 0
  while (start < before.length && next[start] === before[start]) start++
  let end = 0
  while (end < Math.min(before.length, next.length) - start && next.at(-1 - end) === before.at(-1 - end)) end++
  // Deleting text from a legacy title above the limit inserts nothing
  if (start + end === next.length) return title
  const boundaries = [0]
  for (const { segment } of graphemes.segment(title)) boundaries.push(boundaries.at(-1)! + [...segment].length)
  // The kept text after the edit starts at a grapheme cluster boundary
  end = next.length - boundaries.find(boundary => boundary >= next.length - end)!
  const cut = boundaries.findLast(boundary => boundary > start && boundary <= pageTitleMaxLength - end) ?? start
  return cut === start ? previous : next.slice(0, cut).join('') + next.slice(next.length - end).join('')
}

export const pageAPI = {
  viewers: (id: string, cursor?: string, signal?: AbortSignal) =>
    podPageViewers({ path: { id }, query: { cursor, limit: 25 }, signal }),
  thread: (id: string, comment_id: string, signal?: AbortSignal) =>
    podCommentRead({ path: { id, comment_id }, signal }),
  navigation: (activePageID?: string, signal?: AbortSignal) =>
    podPageNavigation({ query: { active_page_id: activePageID }, signal }),
  list: (scope: PageScope, query = '', signal?: AbortSignal) =>
    podPageList({ query: { scope, query: query.trim() || undefined }, signal }),
  children: (scope: 'space' | 'private', parentID?: string, cursor?: string, signal?: AbortSignal) =>
    podPageChildren({
      query: { ...(parentID ? { parent_id: parentID } : { scope }), ...(cursor ? { cursor } : {}), limit: 200 },
      signal
    }),
  subpages: (scope: 'space' | 'private', parentID: string, cursor?: string, signal?: AbortSignal) =>
    podPageChildren({
      query: { parent_id: parentID, scope, ...(cursor ? { cursor } : {}), limit: 200, details: true },
      signal
    }),
  search: (query: string, options: PageSearchOptions = {}, signal?: AbortSignal) =>
    podPageSearch({ query: { ...options, query: query.trim() }, signal }),
  read: (id: string, signal?: AbortSignal) => podPageRead({ path: { id }, signal }),
  insights: (id: string, signal?: AbortSignal) => podPageInsights({ path: { id }, signal }),
  history: (id: string, cursor?: string, signal?: AbortSignal) =>
    podPageHistory({ path: { id }, query: { cursor, limit: 25 }, signal }),
  snapshot: (id: string, snapshot_id: string, signal?: AbortSignal) =>
    podPageHistoryEntry({ path: { id, snapshot_id }, signal }),
  restoreSnapshot: (id: string, snapshot_id: string, body: { base_revision: number; updated_at: string }) =>
    podPageHistoryRestore({ path: { id, snapshot_id }, body: { data: body } }),
  comments: (id: string, status: 'open' | 'resolved' | 'all' | 'unread', cursor?: string, signal?: AbortSignal) =>
    podPageComments({ path: { id }, query: { status, cursor, limit: 25 }, signal }),
  commentSummary: (id: string, signal?: AbortSignal) => podPageCommentSummary({ path: { id }, signal }),
  readComments: (id: string, through: string) => podPageCommentsRead({ path: { id }, body: { data: { through } } }),
  comment: (
    id: string,
    body: {
      body: string
      root_id?: string
      base_revision?: number
      from?: number
      to?: number
      anchor?: Record<string, unknown> | null
      quote?: string | null
      mentioned_agent_uids?: string[] | null
    }
  ) => podPageCommentCreate({ path: { id }, body: { data: body } }),
  editComment: (
    id: string,
    comment_id: string,
    body: { body: string; version: number; mentioned_agent_uids?: string[] | null }
  ) => podPageCommentUpdate({ path: { id, comment_id }, body: { data: body } }),
  deleteComment: (id: string, comment_id: string, version: number) =>
    podPageCommentDelete({ path: { id, comment_id }, query: { version } }),
  resolveComment: (id: string, comment_id: string, resolved: boolean, version: number) =>
    podPageCommentResolve({ path: { id, comment_id }, body: { data: { resolved, version } } }),
  anchorComment: (
    id: string,
    comment_id: string,
    body: {
      base_revision?: number | null
      from?: number | null
      to?: number | null
      anchor?: Record<string, unknown> | null
      quote?: string | null
      version: number
    }
  ) => podPageCommentAnchor({ path: { id, comment_id }, body: { data: body } }),
  create: (body: NonNullable<PodPageCreateData['body']>['data']) => podPageCreate({ body: { data: body } }),
  update: (id: string, body: NonNullable<PodPageUpdateData['body']>['data']) =>
    podPageUpdate({ path: { id }, body: { data: body } }),
  move: (id: string, body: PageMove) => podPageMove({ path: { id }, body: { data: body } }),
  remove: (id: string) => podPageDelete({ path: { id } }),
  removeEmbeds: (id: string, refs: readonly string[]) =>
    podEmbedsDelete({ path: { id }, body: { data: { refs: [...refs] } } }),
  restore: (id: string) => podPageRestore({ path: { id } }),
  purge: (id: string) => podPagePurge({ path: { id } }),
  state: (id: string, body: NonNullable<PodPageUserStateData['body']>['data']) =>
    podPageUserState({ path: { id }, body: { data: body } }),
  sharing: (id: string, signal?: AbortSignal) => podPageSharing({ path: { id }, signal }),
  updateSharing: (id: string, body: PageSharingUpdate) => podPageSharingUpdate({ path: { id }, body: { data: body } }),
  share: (id: string, body: PageSharing) => podPageSharingWrite({ path: { id }, body: { data: body } }),
  mentionCandidates: (
    query: string,
    category: MentionCategoryParam = 'all',
    currentPageID?: string,
    signal?: AbortSignal
  ) =>
    podMentionCandidates({
      query: {
        query,
        category,
        ...(currentPageID ? { current_page_id: currentPageID } : {}),
        limit: 20
      },
      signal
    }),
  resolveMentions: (body: MentionsResolveInput, signal?: AbortSignal) =>
    podMentionsResolve({ body: { data: body }, signal })
}

export const pagesQuery = (scope: PageScope, query = '') => ({
  queryKey: contentKeys.list(scope, query),
  queryFn: ({ client, signal }: { client: QueryClient; signal: AbortSignal }) =>
    pageMetadata(client).read(
      () => pageAPI.list(scope, query, signal),
      result => result.pages
    )
})
export const pageSearchQuery = (query: string, options: PageSearchOptions = {}) => ({
  queryKey: contentKeys.search(query.trim(), options),
  queryFn: ({ client, signal }: { client: QueryClient; signal: AbortSignal }) =>
    pageMetadata(client).read(
      () => pageAPI.search(query, options, signal),
      result => [...result.pages, ...result.ancestors]
    )
})
export const pageChildrenQuery = (scope: 'space' | 'private', parentID?: string) => ({
  queryKey: contentKeys.children(scope, parentID),
  initialPageParam: undefined as string | undefined,
  staleTime: 60_000,
  queryFn: ({
    client,
    pageParam,
    signal
  }: {
    client: QueryClient
    pageParam: string | undefined
    signal: AbortSignal
  }) =>
    pageMetadata(client).read(
      () => pageAPI.children(scope, parentID, pageParam, signal),
      result => result.pages
    ),
  getNextPageParam: (last: PodPageChildrenResponse) => last.next_cursor ?? undefined
})
const selectDirectoryCapabilities = (data: InfiniteData<PodPageChildrenResponse>) => {
  const root = data.pages[0]
  if (!root) return undefined
  return {
    principal_uid: root.principal_uid,
    can_create_private: root.can_create_private,
    can_create_space: root.can_create_space,
    can_manage_space: root.can_manage_space
  }
}
export const directoryCapabilitiesQuery = () => ({
  ...pageChildrenQuery('space'),
  select: selectDirectoryCapabilities
})
export const pageSubpagesQuery = (scope: 'space' | 'private', parentID: string) => ({
  queryKey: contentKeys.subpages(scope, parentID),
  initialPageParam: undefined as string | undefined,
  staleTime: 30_000,
  queryFn: ({
    client,
    pageParam,
    signal
  }: {
    client: QueryClient
    pageParam: string | undefined
    signal: AbortSignal
  }) =>
    pageMetadata(client).read(
      () => pageAPI.subpages(scope, parentID, pageParam, signal),
      result => result.pages
    ),
  getNextPageParam: (last: PodPageChildrenResponse) => last.next_cursor ?? undefined
})

export const pageQuery = (id: string) => ({
  queryKey: contentKeys.page(id),
  staleTime: 15_000,
  queryFn: ({ client, signal }: { client: QueryClient; signal: AbortSignal }) =>
    pageMetadata(client).read(
      () => pageAPI.read(id, signal),
      result => [result.page, ...result.ancestors]
    ),
  retry: false
})

export const pageInsightsQuery = (id: string) => ({
  queryKey: contentKeys.insights(id),
  queryFn: ({ signal }: { signal: AbortSignal }) => pageAPI.insights(id, signal),
  retry: false
})

export const pageViewersQuery = (id: string) => ({
  queryKey: [...contentKeys.page(id), 'viewers'],
  initialPageParam: undefined as string | undefined,
  queryFn: ({ pageParam, signal }: { pageParam: string | undefined; signal: AbortSignal }) =>
    pageAPI.viewers(id, pageParam, signal),
  getNextPageParam: (last: Awaited<ReturnType<typeof pageAPI.viewers>>) => last.next_cursor ?? undefined,
  retry: false
})

export const pageHistoryQuery = (id: string) => ({
  queryKey: contentKeys.history(id),
  initialPageParam: undefined as string | undefined,
  queryFn: ({ pageParam, signal }: { pageParam: string | undefined; signal: AbortSignal }) =>
    pageAPI.history(id, pageParam, signal),
  getNextPageParam: (last: Awaited<ReturnType<typeof pageAPI.history>>) => last.next_cursor ?? undefined,
  retry: false
})

export const pageSnapshotQuery = (id: string, snapshotID: string) => ({
  queryKey: contentKeys.snapshot(id, snapshotID),
  queryFn: ({ signal }: { signal: AbortSignal }) => pageAPI.snapshot(id, snapshotID, signal),
  retry: false
})

export const pageCommentQuery = (id: string, commentID: string) => ({
  queryKey: [...contentKeys.comments(id), 'thread', commentID],
  queryFn: ({ signal }: { signal: AbortSignal }) => pageAPI.thread(id, commentID, signal),
  retry: false
})

export const pageCommentSummaryQuery = (id: string) => ({
  queryKey: contentKeys.commentSummary(id),
  queryFn: ({ signal }: { signal: AbortSignal }) => pageAPI.commentSummary(id, signal),
  retry: false
})

export const pageCommentsQuery = (id: string, status: 'open' | 'resolved' | 'all' | 'unread') => ({
  queryKey: contentKeys.comments(id, status),
  initialPageParam: undefined as string | undefined,
  queryFn: ({ pageParam, signal }: { pageParam: string | undefined; signal: AbortSignal }) =>
    pageAPI.comments(id, status, pageParam, signal),
  getNextPageParam: (last: Awaited<ReturnType<typeof pageAPI.comments>>) => last.next_cursor ?? undefined,
  retry: false
})

export function cachedPages(client: QueryClient): Page[] {
  const pages = new Map<string, Page>()
  for (const [, data] of client.getQueriesData<{
    pages?: Page[] | { pages: Page[] }[]
    path?: Page[]
  }>({
    queryKey: contentKeys.lists
  })) {
    for (const item of data?.pages ?? []) {
      for (const page of 'pages' in item ? item.pages : [item]) pages.set(page.id, page)
    }
    for (const page of data?.path ?? []) pages.set(page.id, page)
  }
  return [...pages.values()]
}

export function fileURL(id: string, path: string, sha256?: string): string {
  const params = new URLSearchParams({ path, ...(sha256 ? { sha256 } : {}), ...identityQuery() })
  return `/api/v2/pod${pagePath(id)}/files/content?${params}`
}

/** A tenant-wide file under `metadata/`, outside any Page directory. */
export function metadataFileURL(path: string): string {
  const params = new URLSearchParams({ path, ...identityQuery() })
  return `/api/v2/pod/metadata/files/content?${params}`
}

export function identityQuery(): Record<string, string> {
  const authentication = authenticationRef()
  return authentication ? { authentication_ref: authentication } : {}
}
