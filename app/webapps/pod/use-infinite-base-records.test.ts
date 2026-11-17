import { describe, expect, test } from 'bun:test'
import { QueryClient, type InfiniteData } from '@tanstack/react-query'
import type { BaseField, BaseRecord, RecordQuery, RecordsResult } from '@ankole/applet-sdk/types'
import { reconcileInfiniteRecordQueries, trimInfiniteRecordQueriesToFirstPage } from './base-api'
import { mergeRetainedDetailRecord } from './base-card-views'
import { dedupeInfinitePages, INFINITE_RECORDS_SEGMENT } from './use-infinite-base-records'

function makeRecord(id: string, data: Record<string, unknown> = {}): BaseRecord {
  return {
    id,
    data: data as BaseRecord['data'],
    versions: { title: 1, amount: 1 },
    created_at: '2026-11-16T00:00:00Z',
    updated_at: '2026-11-16T00:00:00Z',
    created_by: 'alice',
    updated_by: 'alice'
  }
}

const fields: BaseField[] = [
  { id: 'title', name: 'Title', description: '', type: 'text', config: {}, version: 1, is_primary: true },
  { id: 'amount', name: 'Amount', description: '', type: 'number', config: {}, version: 1, is_primary: false }
]

describe('useInfiniteBaseRecords cache reconciliation', () => {
  test('dedupeInfinitePages preserves first-seen order and drops cursor boundary duplicates', () => {
    const pages: RecordsResult[] = [
      { records: [makeRecord('r1'), makeRecord('r2')], data_version: 1, page_token: 'c1', complete: false },
      { records: [makeRecord('r2'), makeRecord('r3')], data_version: 2, page_token: null, complete: true }
    ]
    expect(dedupeInfinitePages(pages).map(record => record.id)).toEqual(['r1', 'r2', 'r3'])
  })

  test('editing an unsorted field patches multiple loaded pages in place without refetching all pages', () => {
    const client = new QueryClient()
    const prefix = ['content', 'table', 'tbl_1'] as const
    const querySpec: RecordQuery = { sort: [{ field_id: 'amount', direction: 'desc' }], page_size: 2 }
    const queryKey = [...prefix, INFINITE_RECORDS_SEGMENT, querySpec] as const

    client.setQueryData<InfiniteData<RecordsResult, string | undefined>>(queryKey, {
      pages: [
        {
          records: [makeRecord('r1', { title: 'Old', amount: 100 }), makeRecord('r2', { title: 'Keep', amount: 90 })],
          data_version: 3,
          page_token: 'c1',
          complete: false
        },
        {
          records: [makeRecord('r3', { title: 'Page2', amount: 50 })],
          data_version: 3,
          page_token: 'c2',
          complete: false
        }
      ],
      pageParams: [undefined, 'c1']
    })

    const refetchHashes = reconcileInfiniteRecordQueries(client, prefix, {
      fields,
      updatedRecords: [makeRecord('r3', { title: 'Updated in place', amount: 50 })],
      deletedIDs: ['r2'],
      dataVersion: 4,
      touchedFields: new Set(['title'])
    })

    expect(refetchHashes.size).toBe(0)
    const updated = client.getQueryData<InfiniteData<RecordsResult, string | undefined>>(queryKey)!
    expect(updated.pages).toHaveLength(2)
    expect(updated.pages[0]!.records.map(r => r.id)).toEqual(['r1'])
    expect(updated.pages[1]!.records[0]!.data.title).toBe('Updated in place')
    expect(updated.pages[1]!.data_version).toBe(4)
  })

  test('editing a sorted field or creating a row trims multi-page cache to page 1 to avoid serial refetch storms', () => {
    const client = new QueryClient()
    const prefix = ['content', 'table', 'tbl_1'] as const
    const querySpec: RecordQuery = { sort: [{ field_id: 'amount', direction: 'desc' }], page_size: 2 }
    const queryKey = [...prefix, INFINITE_RECORDS_SEGMENT, querySpec] as const

    client.setQueryData<InfiniteData<RecordsResult, string | undefined>>(queryKey, {
      pages: [
        { records: [makeRecord('r1', { amount: 100 })], data_version: 3, page_token: 'c1', complete: false },
        { records: [makeRecord('r2', { amount: 90 })], data_version: 3, page_token: 'c2', complete: false },
        { records: [makeRecord('r3', { amount: 80 })], data_version: 3, page_token: 'c3', complete: false }
      ],
      pageParams: [undefined, 'c1', 'c2']
    })

    const refetchHashes = reconcileInfiniteRecordQueries(client, prefix, {
      fields,
      updatedRecords: [makeRecord('r3', { amount: 500 })],
      deletedIDs: [],
      dataVersion: 4,
      touchedFields: new Set(['amount'])
    })

    expect(refetchHashes.size).toBe(1)
    const trimmed = client.getQueryData<InfiniteData<RecordsResult, string | undefined>>(queryKey)!
    expect(trimmed.pages).toHaveLength(1)
    expect(trimmed.pageParams).toEqual([undefined])

    // Also verify explicit trim helper
    client.setQueryData<InfiniteData<RecordsResult, string | undefined>>(queryKey, {
      pages: [trimmed.pages[0]!, { records: [makeRecord('r2')], data_version: 4, page_token: null, complete: true }],
      pageParams: [undefined, 'c1']
    })
    trimInfiniteRecordQueriesToFirstPage(client, prefix)
    expect(client.getQueryData<InfiniteData<RecordsResult, string | undefined>>(queryKey)!.pages).toHaveLength(1)
  })

  test('a version gap (data_version jumping from 1 to 3) trims and invalidates instead of patching over missed versions', () => {
    const client = new QueryClient()
    const prefix = ['content', 'table', 'tbl_1'] as const
    const querySpec: RecordQuery = { sort: [{ field_id: 'amount', direction: 'desc' }], page_size: 2 }
    const queryKey = [...prefix, INFINITE_RECORDS_SEGMENT, querySpec] as const

    client.setQueryData<InfiniteData<RecordsResult, string | undefined>>(queryKey, {
      pages: [
        {
          records: [makeRecord('r1', { title: 'V1', amount: 100 })],
          data_version: 1,
          page_token: 'c1',
          complete: false
        },
        {
          records: [makeRecord('r2', { title: 'V1-p2', amount: 50 })],
          data_version: 1,
          page_token: null,
          complete: true
        }
      ],
      pageParams: [undefined, 'c1']
    })

    const refetchHashes = reconcileInfiniteRecordQueries(client, prefix, {
      fields,
      updatedRecords: [makeRecord('r1', { title: 'V3', amount: 100 })],
      deletedIDs: [],
      dataVersion: 3,
      touchedFields: new Set(['title'])
    })

    expect(refetchHashes.size).toBe(1)
    const trimmed = client.getQueryData<InfiniteData<RecordsResult, string | undefined>>(queryKey)!
    expect(trimmed.pages).toHaveLength(1)
    expect(trimmed.pageParams).toEqual([undefined])
  })

  test('mergeRetainedDetailRecord keeps an open page-2 record mounted after pagination trims to page 1', () => {
    const client = new QueryClient()
    const prefix = ['content', 'table', 'tbl_1'] as const
    const querySpec: RecordQuery = { sort: [{ field_id: 'amount', direction: 'desc' }], page_size: 2 }
    const queryKey = [...prefix, INFINITE_RECORDS_SEGMENT, querySpec] as const
    const page2Record = makeRecord('r3', { title: 'Deep row', amount: 80 })

    client.setQueryData<InfiniteData<RecordsResult, string | undefined>>(queryKey, {
      pages: [
        {
          records: [makeRecord('r1', { title: 'Top', amount: 100 })],
          data_version: 3,
          page_token: 'c1',
          complete: false
        },
        { records: [page2Record], data_version: 3, page_token: null, complete: true }
      ],
      pageParams: [undefined, 'c1']
    })

    // Simulate a collaborator insert that trims loaded pages back to page 1.
    reconcileInfiniteRecordQueries(client, prefix, {
      fields,
      updatedRecords: [makeRecord('r4', { title: 'New collaborator row', amount: 200 })],
      deletedIDs: [],
      dataVersion: 4
    })

    const trimmedRecords = dedupeInfinitePages(
      client.getQueryData<InfiniteData<RecordsResult, string | undefined>>(queryKey)!.pages
    )
    expect(trimmedRecords.map(r => r.id)).toEqual(['r1'])
    expect(mergeRetainedDetailRecord(page2Record, trimmedRecords)).toEqual(page2Record)

    // When the page-2 row re-enters loaded records with newer data, the live record supersedes the snapshot.
    const refreshed = makeRecord('r3', { title: 'Deep row updated', amount: 80 })
    expect(mergeRetainedDetailRecord(page2Record, [...trimmedRecords, refreshed])).toEqual(refreshed)
  })
})
