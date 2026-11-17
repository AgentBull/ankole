import { useMemo } from 'react'
import { useInfiniteQuery, useMutationState, useQueryClient, type InfiniteData } from '@tanstack/react-query'
import { usePod, useRecordWrites, useTableReadDenial } from '@ankole/applet-sdk'
import { previewRecordList } from '@ankole/applet-sdk/records'
import type { BaseRecord, RecordQuery, RecordWrite, RecordsResult } from '@ankole/applet-sdk/types'
import { InternalAPIError } from '../common/internal-api-client'
import { requestErrorCode } from '../common/request-errors'

export type InfiniteRecordQuery = Omit<RecordQuery, 'page_token' | 'page_size'>

export const INFINITE_RECORDS_SEGMENT = 'infinite-records'

export function dedupeInfinitePages(pages: readonly RecordsResult[]): BaseRecord[] {
  const seen = new Set<string>()
  const merged: BaseRecord[] = []
  for (const page of pages) {
    for (const record of page.records) {
      if (seen.has(record.id)) continue
      seen.add(record.id)
      merged.push(record)
    }
  }
  return merged
}

export function useInfiniteBaseRecords(tableID: string, baseQuery: InfiniteRecordQuery = {}, pageSize = 200) {
  const runtime = usePod()
  const client = useQueryClient()

  const normalizedQuery: RecordQuery = useMemo(() => ({ ...baseQuery, page_size: pageSize }), [baseQuery, pageSize])
  const queryKey = useMemo(
    () => [...runtime.base.key(tableID), INFINITE_RECORDS_SEGMENT, normalizedQuery] as const,
    [runtime, tableID, normalizedQuery]
  )
  const { revoked, resolveDenial } = useTableReadDenial(runtime, tableID, queryKey)

  const read = useInfiniteQuery<
    RecordsResult,
    Error,
    InfiniteData<RecordsResult, string | undefined>,
    typeof queryKey,
    string | undefined
  >({
    queryKey,
    initialPageParam: undefined,
    queryFn: async ({ pageParam }) => {
      const request: RecordQuery =
        pageParam === undefined ? normalizedQuery : { ...normalizedQuery, page_token: pageParam }
      try {
        return await runtime.base.records(tableID, request)
      } catch (error) {
        if (
          pageParam !== undefined &&
          error instanceof InternalAPIError &&
          requestErrorCode(error.payload) === 'invalid_page_token'
        ) {
          await client.resetQueries({ queryKey, exact: true })
        }
        throw error
      }
    },
    getNextPageParam: lastPage => lastPage.page_token ?? undefined,
    enabled: !revoked
  })

  const deniedError = resolveDenial(read.error, read.failureReason)

  const write = useRecordWrites(tableID)
  const pending = useMutationState({
    filters: { mutationKey: [...runtime.base.key(tableID), 'write'], status: 'pending' },
    select: mutation => mutation.state.variables as RecordWrite
  })

  const merged = useMemo(
    () => (deniedError || !read.data ? [] : dedupeInfinitePages(read.data.pages)),
    [deniedError, read.data]
  )
  const records = useMemo(() => (deniedError ? [] : previewRecordList(merged, pending)), [deniedError, merged, pending])

  const initialError = deniedError ?? (read.isLoadingError || (!read.data && read.error) ? read.error : null)
  const fetchNextError = !deniedError && read.isFetchNextPageError ? read.error : undefined

  return {
    records,
    dataVersion: deniedError ? undefined : read.data?.pages.at(-1)?.data_version,
    isPending: deniedError ? false : read.isPending,
    isFetching: read.isFetching,
    hasNextPage: deniedError ? false : Boolean(read.hasNextPage),
    isFetchingNextPage: deniedError ? false : read.isFetchingNextPage,
    error: initialError,
    fetchNextError,
    fetchNextPage: () => {
      if (!deniedError && read.hasNextPage && !read.isFetchingNextPage) {
        void read.fetchNextPage()
      }
    },
    refetch: read.refetch,
    ...write
  }
}
