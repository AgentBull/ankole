import { expect, test } from 'bun:test'
import { isAdvancedSharingRule, PageSharingModel } from './page-sharing'
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
      actions: ['page_view'],
      source_page: { id: 'source', accessible: false, title: null, icon: null }
    }
  ]
})

test('CAS recovery keeps the edited rule and changes only the captured version', () => {
  const model = new PageSharingModel()
  model.replace(sharing('v1'))
  model.update(0, { role: 'edit', target_scope: 'container' })
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
  expect(model.body()?.grants?.[0]?.actions).toEqual(['page_view'])
  expect(model.body()?.grants?.[0]).not.toHaveProperty('role')
  expect(model.conflictReloaded.value).toBe(false)
  model[Symbol.dispose]()
})

test('saving a userset sends rule fields and preserves redacted source metadata only in the draft', () => {
  const model = new PageSharingModel()
  model.replace(sharing('v1'))
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

test('advanced rules preserve actual actions while ordinary role edits send the selected role', () => {
  const model = new PageSharingModel()
  const source = sharing('v1')
  source.grants[0] = { ...source.grants[0]!, role: 'contribute', actions: ['page_write_records'] }
  model.replace(source)
  expect(model.body()?.grants?.[0]?.actions).toEqual(['page_write_records'])
  expect(model.body()?.grants?.[0]).not.toHaveProperty('role')
  model.add({
    kind: 'human',
    name: 'Member',
    principal_uid: 'member',
    role: 'edit',
    condition: 'true',
    target_scope: 'container',
    actions: ['page_edit']
  })
  expect(model.body()?.grants?.[1]?.actions).toEqual(['page_edit'])
  model.update(1, { role: 'contribute' })
  expect(model.body()?.grants?.[1]?.role).toBe('contribute')
  expect(model.body()?.grants?.[1]).not.toHaveProperty('actions')
  model[Symbol.dispose]()
})

test('a partial direct grant is shown as actual actions instead of a complete business role', () => {
  const grant = {
    kind: 'human' as const,
    name: 'Member',
    principal_uid: 'member',
    role: 'contribute' as const,
    condition: 'true',
    actions: ['page_write_records' as const]
  }
  expect(isAdvancedSharingRule(grant)).toBe(true)
  expect(isAdvancedSharingRule({ ...grant, actions: ['page_view', 'page_write_records'] })).toBe(false)
  expect(isAdvancedSharingRule({ ...grant, actions: undefined })).toBe(false)
  expect(isAdvancedSharingRule({ ...grant, condition: 'context.request.ip == "10.0.0.1"' })).toBe(true)
})

test('adding the same audience updates its role while scopes and conditions remain independent', () => {
  const model = new PageSharingModel()
  model.replace(sharing('v1'))
  const grant = sharing('v1').grants[0]!
  model.add({ ...grant, role: 'edit' })
  expect(model.draft.value?.grants).toHaveLength(1)
  expect(model.draft.value?.grants[0]?.role).toBe('edit')
  model.add({ ...grant, target_scope: 'container' })
  model.add({ ...grant, condition: 'true' })
  expect(model.draft.value?.grants).toHaveLength(3)
  model[Symbol.dispose]()
})

test('new grants default to container scope while role edits preserve existing self scope', () => {
  const model = new PageSharingModel()
  model.replace({ sharing_version: 'v1', inherit_permissions: true, subjects: [], grants: [] })
  model.add({
    kind: 'human',
    name: 'Alice',
    principal_uid: 'alice',
    role: 'view',
    condition: 'true'
  })
  expect(model.draft.value?.grants[0]?.target_scope).toBe('container')
  expect(model.body()?.grants?.[0]?.target_scope).toBe('container')

  model.add({
    kind: 'human',
    name: 'Bob',
    principal_uid: 'bob',
    role: 'view',
    target_scope: 'self',
    condition: 'true'
  })
  model.update(1, { role: 'edit' })
  expect(model.draft.value?.grants[1]?.target_scope).toBe('self')
  expect(model.body()?.grants?.[1]).toMatchObject({
    principal_uid: 'bob',
    role: 'edit',
    target_scope: 'self'
  })
  model[Symbol.dispose]()
})
