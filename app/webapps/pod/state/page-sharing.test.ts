import { expect, test } from 'bun:test'
import { PageSharingModel } from './page-sharing'
import type { PodPageSharingResponse } from '../api/generated/types.gen'

const sharing = (version: string): PodPageSharingResponse => ({
  sharing_version: version,
  inherit_permissions: true,
  subjects: [],
  grants: [
    {
      kind: 'userset',
      name: 'Restricted page',
      principal_uid: null,
      group_id: null,
      source_page_id: 'source',
      source_action: 'page_view',
      role: 'view',
      target_scope: 'self',
      condition: 'context.request.ip == "10.0.0.1"',
      source_page: { id: 'source', accessible: false, title: null, icon: null }
    }
  ]
})

test('sharing refetch keeps the edited rule and CAS recovery changes only the captured version', () => {
  const model = new PageSharingModel()
  model.initialize(sharing('v1'))
  model.update(0, { role: 'edit', target_scope: 'container' })
  model.initialize(sharing('v2'))
  expect(model.draft.value?.sharing_version).toBe('v1')
  expect(model.draft.value?.grants[0]?.role).toBe('edit')
  model.keepDraft('v2')
  expect(model.body()).toEqual({
    sharing_version: 'v2',
    inherit_permissions: true,
    grants: [
      {
        principal_uid: null,
        group_id: null,
        source_page_id: 'source',
        source_action: 'page_view',
        role: 'edit',
        target_scope: 'container',
        condition: 'context.request.ip == "10.0.0.1"'
      }
    ]
  })
  expect(model.conflictReloaded.value).toBe(true)
  model.replace(sharing('v3'))
  expect(model.body()?.sharing_version).toBe('v3')
  expect(model.body()?.grants?.[0]?.role).toBe('view')
  expect(model.conflictReloaded.value).toBe(false)
  model[Symbol.dispose]()
})

test('saving a userset sends rule fields and preserves redacted source metadata only in the draft', () => {
  const model = new PageSharingModel()
  model.initialize(sharing('v1'))
  const grant = model.body()?.grants?.[0]
  expect(grant).not.toHaveProperty('name')
  expect(grant).not.toHaveProperty('source_page')
  expect(model.draft.value?.grants[0]?.source_page).toEqual({
    id: 'source',
    accessible: false,
    title: null,
    icon: null
  })
  model[Symbol.dispose]()
})

test('adding the same audience updates its role while scopes and conditions remain independent', () => {
  const model = new PageSharingModel()
  model.initialize(sharing('v1'))
  const grant = sharing('v1').grants[0]!
  model.add({ ...grant, role: 'edit' })
  expect(model.draft.value?.grants).toHaveLength(1)
  expect(model.draft.value?.grants[0]?.role).toBe('edit')
  model.add({ ...grant, target_scope: 'container' })
  model.add({ ...grant, condition: 'true' })
  expect(model.draft.value?.grants).toHaveLength(3)
  model[Symbol.dispose]()
})
