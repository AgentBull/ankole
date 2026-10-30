import { expect, test } from 'bun:test'
import {
  buildRemoveTarget,
  buildRoleUpsertPatch,
  effectiveCollaboratorPreview,
  isAdvancedSharingRule,
  PageSharingModel,
  partitionSharingGrants,
  sortCandidateSubjects,
  subjectKey
} from './page-sharing'

test('staging a subject transitions to invite view, deduplicates selections, and builds a batch upsert patch', () => {
  const model = new PageSharingModel()
  const alice = { kind: 'human' as const, name: 'Alice', principal_uid: 'alice', membership: 'member' as const }
  const helperAgent = { kind: 'agent' as const, name: 'Research Agent', principal_uid: 'agent-1' }

  model.query.value = 'ali'
  model.browseOpen.value = true
  model.stageSubject(alice, 'edit')

  expect(model.view.value).toBe('invite')
  expect(model.query.value).toBe('')
  expect(model.browseOpen.value).toBe(false)
  expect(model.stagedRole.value).toBe('edit')
  expect(model.hasStagedAgents.value).toBe(false)

  model.stageSubject(alice, 'view')
  expect(model.staged.value).toHaveLength(1)
  expect(model.stagedRole.value).toBe('edit')

  model.stageSubject(helperAgent)
  expect(model.staged.value).toHaveLength(2)
  expect(model.hasStagedAgents.value).toBe(true)

  model.stagedScope.value = 'self'
  expect(model.buildInvitePatch()).toEqual({
    upserts: [
      { principal_uid: 'alice', group_id: null, role: 'edit', target_scope: 'self' },
      { principal_uid: 'agent-1', group_id: null, role: 'edit', target_scope: 'self' }
    ]
  })

  model.unstageSubject(subjectKey(alice))
  expect(model.staged.value).toEqual([helperAgent])

  model.backToMain()
  expect(model.view.peek()).toBe('main')
  expect(model.staged.peek()).toEqual([])
  expect(model.stagedRole.peek()).toBe('view')
  expect(model.stagedScope.peek()).toBe('container')
  expect(model.buildInvitePatch()).toBeUndefined()

  model.stageSubject(alice, 'contribute', 'self')
  expect(model.stagedRole.value).toBe('contribute')
  expect(model.stagedScope.value).toBe('self')
  model[Symbol.dispose]()
})

test('collaborator and settings subviews reset transient search state cleanly', () => {
  const model = new PageSharingModel()
  model.query.value = 'group'
  model.browseOpen.value = true

  model.openCollaborators('self')
  expect(model.view.value).toBe('collaborators')
  expect(model.scopeTab.value).toBe('self')
  expect(model.query.value).toBe('')
  expect(model.browseOpen.value).toBe(false)

  model.openInvite(model.scopeTab.value, 'contribute')
  expect(model.view.value).toBe('invite')
  expect(model.stagedScope.value).toBe('self')
  expect(model.stagedRole.value).toBe('contribute')

  model.openSettings()
  expect(model.view.value).toBe('settings')

  model.reset()
  expect(model.view.value).toBe('main')
  expect(model.scopeTab.value).toBe('container')
  expect(model.stagedScope.value).toBe('container')
  expect(model.stagedRole.value).toBe('view')
  model[Symbol.dispose]()
})

test('isAdvancedSharingRule follows the authoritative rule_kind returned by the server', () => {
  expect(isAdvancedSharingRule({ rule_kind: 'role' })).toBe(false)
  expect(isAdvancedSharingRule({ rule_kind: 'advanced' })).toBe(true)
})

test('effectiveCollaboratorPreview deduplicates direct and inherited collaborators while skipping inactive guest or advanced rules', () => {
  const preview = effectiveCollaboratorPreview(
    {
      inherited: [
        {
          kind: 'group',
          group_id: 'admins',
          name: 'Pod Administrators',
          origin: 'space_admin',
          role: 'manage'
        },
        {
          kind: 'human',
          principal_uid: 'alice',
          name: 'Alice',
          origin: 'ancestor',
          role: 'view'
        }
      ],
      grants: [
        {
          kind: 'human',
          principal_uid: 'alice',
          name: 'Alice',
          role: 'edit',
          rule_kind: 'role',
          target_scope: 'container',
          condition: 'true',
          actions: ['page_view', 'page_comment', 'page_write_records', 'page_edit'],
          inactive_in_private: false
        },
        {
          kind: 'human',
          principal_uid: 'guest-1',
          membership: 'guest',
          name: 'Inactive Guest',
          role: 'view',
          rule_kind: 'role',
          target_scope: 'container',
          condition: 'true',
          actions: ['page_view'],
          inactive_in_private: true
        },
        {
          kind: 'userset',
          name: 'Source page',
          source_page_id: 'src',
          source_action: 'page_view',
          role: 'view',
          rule_kind: 'advanced',
          target_scope: 'self',
          condition: 'true',
          actions: ['page_view'],
          inactive_in_private: false
        },
        {
          kind: 'human',
          principal_uid: 'bob',
          name: 'Bob',
          role: 'view',
          rule_kind: 'role',
          target_scope: 'self',
          condition: 'true',
          actions: ['page_view'],
          inactive_in_private: false
        }
      ]
    },
    2
  )

  expect(preview.total).toBe(3)
  expect(preview.overflow).toBe(1)
  expect(preview.items.map(item => item.name)).toEqual(['Alice', 'Bob'])
})

test('buildRemoveTarget normalizes scope and condition for granular removal', () => {
  expect(
    buildRemoveTarget({
      kind: 'userset',
      name: 'Restricted',
      source_page_id: 'source-id',
      source_action: 'page_view',
      role: 'view',
      target_scope: 'self',
      condition: ' context.request.ip == "10.0.0.1" '
    })
  ).toEqual({
    principal_uid: null,
    group_id: null,
    source_page_id: 'source-id',
    source_action: 'page_view',
    condition: 'context.request.ip == "10.0.0.1"',
    target_scope: 'self'
  })
  expect(buildRoleUpsertPatch({ principal_uid: 'alice', group_id: null }, 'manage', 'container')).toEqual({
    upserts: [{ principal_uid: 'alice', group_id: null, role: 'manage', target_scope: 'container' }]
  })
})

test('partitionSharingGrants and sortCandidateSubjects group rules and push blocked guests or existing grants last', () => {
  const roles = { view: 'View', edit: 'Edit', manage: 'Manage' }
  const { ordinaryGrants, advancedGrants, directByKey } = partitionSharingGrants(
    [
      {
        kind: 'human',
        principal_uid: 'alice',
        name: 'Alice',
        role: 'edit',
        rule_kind: 'role',
        target_scope: 'container',
        condition: 'true',
        actions: ['page_view', 'page_comment', 'page_write_records', 'page_edit'],
        inactive_in_private: false
      },
      {
        kind: 'human',
        principal_uid: 'partial',
        name: 'Partial Bitmask',
        role: 'edit',
        rule_kind: 'advanced',
        target_scope: 'container',
        condition: 'true',
        actions: ['page_view', 'page_edit'],
        inactive_in_private: false
      },
      {
        kind: 'human',
        principal_uid: 'commenter',
        name: 'Commenter on file',
        role: 'contribute',
        rule_kind: 'role',
        target_scope: 'container',
        condition: 'true',
        actions: ['page_view', 'page_comment', 'page_write_records'],
        inactive_in_private: false
      }
    ],
    roles
  )

  expect(ordinaryGrants.map(item => item.name)).toEqual(['Alice'])
  expect(advancedGrants.map(item => item.name)).toEqual(['Partial Bitmask', 'Commenter on file'])

  const sorted = sortCandidateSubjects(
    [
      { kind: 'human', principal_uid: 'guest-1', name: 'Guest', membership: 'guest' },
      { kind: 'human', principal_uid: 'alice', name: 'Alice', membership: 'member' },
      { kind: 'human', principal_uid: 'bob', name: 'Bob', membership: 'member' }
    ],
    directByKey,
    true
  )
  expect(sorted.map(item => item.name)).toEqual(['Bob', 'Alice', 'Guest'])
})
