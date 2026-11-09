import { beforeAll, expect, spyOn, test } from 'bun:test'
import { QueryClient } from '@tanstack/react-query'
import type { BaseField, TableSchema } from '@ankole/applet-sdk/types'
import { loadLocale } from '../common/i18n'
import { baseHTTP, baseSchemaQuery } from './base-api'
import { referenceCandidatesQuery } from './base-field-input'
import { contentKeys } from './content-api'

beforeAll(() => loadLocale('en-US'))

test('reference picker delegates display-label search to Base query before pagination for non-text primary fields', async () => {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const targetTableID = '22222222-2222-4222-8222-222222222222'
  const linkField: BaseField = {
    id: 'f_link',
    name: 'Tier',
    description: '',
    type: 'link',
    config: { table_id: targetTableID, multiple: true },
    version: 1,
    is_primary: false
  }
  const selectSchema: TableSchema = {
    table: {
      id: targetTableID,
      page_id: '11111111-1111-4111-8111-111111111111',
      name: 'Plans',
      description: '',
      record_count: 250,
      data_version: 3,
      unique_field_ids: [],
      emit_changes: false
    },
    fields: [
      {
        id: 'f_plan',
        name: 'Plan',
        description: '',
        type: 'select',
        config: {
          options: [
            { id: 'opt_free', name: 'Starter' },
            { id: 'opt_ent', name: 'Enterprise' }
          ]
        },
        version: 1,
        is_primary: true
      }
    ],
    views: [],
    mode: 'remote'
  }
  client.setQueryData(baseSchemaQuery(targetTableID).queryKey, selectSchema)

  const querySpy = spyOn(baseHTTP, 'query').mockResolvedValue({
    records: [
      {
        id: 'rec_185',
        data: { f_plan: 'opt_ent' },
        versions: { f_plan: 1 },
        created_at: '2026-11-09T00:00:00.000000Z',
        updated_at: '2026-11-09T00:00:00.000000Z',
        created_by: 'alice',
        updated_by: 'alice'
      }
    ],
    data_version: 3,
    complete: true,
    page_token: null
  })

  try {
    const result = await client.fetchQuery(
      referenceCandidatesQuery(client, 'page_1', linkField, 'Enterprise', 'cursor_2')
    )
    expect(querySpy).toHaveBeenCalledTimes(1)
    expect(querySpy.mock.calls[0]?.[0]).toBe(targetTableID)
    expect(querySpy.mock.calls[0]?.[1]).toEqual({
      page_size: 100,
      page_token: 'cursor_2',
      search: 'Enterprise'
    })
    expect(result).toEqual({
      items: [{ id: 'rec_185', name: 'Enterprise' }],
      next: undefined
    })

    // Also verify people primary fields format labels from subjects while searching pre-pagination on the server
    const peopleSchema: TableSchema = {
      ...selectSchema,
      fields: [
        { id: 'f_owner', name: 'Owner', description: '', type: 'user', config: {}, version: 1, is_primary: true }
      ]
    }
    client.setQueryData(baseSchemaQuery(targetTableID).queryKey, peopleSchema)
    client.setQueryData([...contentKeys.all, 'subjects'], {
      subjects: [{ kind: 'human', principal_uid: 'zelda', name: 'Zelda Nightingale' }]
    })
    querySpy.mockResolvedValueOnce({
      records: [
        {
          id: 'rec_204',
          data: { f_owner: ['zelda'] },
          versions: { f_owner: 1 },
          created_at: '2026-11-09T00:00:00.000000Z',
          updated_at: '2026-11-09T00:00:00.000000Z',
          created_by: 'alice',
          updated_by: 'alice'
        }
      ],
      data_version: 3,
      complete: true,
      page_token: null
    })

    const peopleResult = await client.fetchQuery(
      referenceCandidatesQuery(client, 'page_1', linkField, 'Nightingale', undefined)
    )
    expect(querySpy).toHaveBeenCalledTimes(2)
    expect(querySpy.mock.calls[1]?.[1]).toEqual({
      page_size: 100,
      page_token: undefined,
      search: 'Nightingale'
    })
    expect(peopleResult).toEqual({
      items: [{ id: 'rec_204', name: 'Zelda Nightingale' }],
      next: undefined
    })
  } finally {
    querySpy.mockRestore()
    client.clear()
  }
})
