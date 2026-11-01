import { batch, computed, createModel, signal } from '@preact/signals-react'
import type { PodPageSharingResponse } from '../api/generated/types.gen'
import type { PageRole, PageSharingUpdate } from '../content-api'

type SharingView = 'main' | 'invite' | 'collaborators' | 'settings'
export type SharingScopeTab = 'container' | 'self'
export type SharingSubject = PodPageSharingResponse['subjects'][number]
export type SharingGrant = PodPageSharingResponse['grants'][number]
export type InheritedCollaborator = PodPageSharingResponse['inherited'][number]

type CollaboratorPreviewItem = {
  key: string
  name: string
  kind: SharingGrant['kind']
  avatar_url?: string | null
  group_domain?: SharingGrant['group_domain']
}

type SharingGrantShape = Omit<SharingGrant, 'actions' | 'inactive_in_private' | 'rule_kind'> & {
  actions?: SharingGrant['actions']
  inactive_in_private?: boolean
  rule_kind?: SharingGrant['rule_kind']
}

export function subjectKey(subject: { principal_uid?: string | null; group_id?: string | null }): string {
  return subject.principal_uid ? `principal:${subject.principal_uid}` : `group:${subject.group_id ?? ''}`
}

export function isAdvancedSharingRule(grant: Pick<SharingGrant, 'rule_kind'>): boolean {
  return grant.rule_kind === 'advanced'
}

export function buildRemoveTarget(grant: SharingGrantShape) {
  return {
    principal_uid: grant.principal_uid ?? null,
    group_id: grant.group_id ?? null,
    source_node_id: grant.source_node_id ?? null,
    source_action: grant.source_action ?? null,
    condition: grant.condition?.trim() || 'true',
    target_scope: grant.target_scope ?? 'container'
  }
}

export function buildRoleUpsertPatch(
  grant: Pick<SharingGrant, 'principal_uid' | 'group_id'>,
  role: PageRole,
  target_scope: SharingScopeTab
): PageSharingUpdate {
  return {
    upserts: [
      {
        principal_uid: grant.principal_uid ?? null,
        group_id: grant.group_id ?? null,
        role,
        target_scope
      }
    ]
  }
}

export function partitionSharingGrants(
  grants: readonly SharingGrant[],
  roles: Partial<Record<PageRole, string>>
): {
  ordinaryGrants: SharingGrant[]
  advancedGrants: SharingGrant[]
  directByKey: Map<string, SharingGrant>
} {
  const ordinaryGrants: SharingGrant[] = []
  const advancedGrants: SharingGrant[] = []
  const directByKey = new Map<string, SharingGrant>()
  for (const grant of grants) {
    if (!isAdvancedSharingRule(grant) && grant.role in roles && (grant.principal_uid || grant.group_id)) {
      ordinaryGrants.push(grant)
      const key = subjectKey(grant)
      if (!directByKey.has(key)) directByKey.set(key, grant)
    } else {
      advancedGrants.push(grant)
    }
  }
  return { ordinaryGrants, advancedGrants, directByKey }
}

export function sortCandidateSubjects(
  subjects: readonly SharingSubject[],
  directByKey: ReadonlyMap<string, unknown>,
  isPrivate: boolean
): SharingSubject[] {
  return [...subjects].sort((a, b) => {
    const guestDiff = Number(isPrivate && a.membership === 'guest') - Number(isPrivate && b.membership === 'guest')
    if (guestDiff !== 0) return guestDiff
    return Number(directByKey.has(subjectKey(a))) - Number(directByKey.has(subjectKey(b)))
  })
}

export function effectiveCollaboratorPreview(
  sharing: Pick<PodPageSharingResponse, 'grants' | 'inherited'>,
  limit = 4
): { items: CollaboratorPreviewItem[]; overflow: number; total: number } {
  const seen = new Map<string, CollaboratorPreviewItem>()
  for (const grant of sharing.grants) {
    if (isAdvancedSharingRule(grant) || grant.inactive_in_private) continue
    if (!grant.principal_uid && !grant.group_id) continue
    const key = subjectKey(grant)
    if (!seen.has(key)) {
      seen.set(key, {
        key,
        name: grant.name,
        kind: grant.kind,
        avatar_url: grant.avatar_url,
        group_domain: grant.group_domain
      })
    }
  }
  for (const item of sharing.inherited) {
    const key = subjectKey(item)
    if (!seen.has(key)) {
      seen.set(key, {
        key,
        name: item.name,
        kind: item.kind,
        avatar_url: item.avatar_url,
        group_domain: item.group_domain
      })
    }
  }
  const all = [...seen.values()]
  const items = all.slice(0, limit)
  return { items, overflow: Math.max(0, all.length - items.length), total: all.length }
}

export const PageSharingModel = createModel(() => {
  const view = signal<SharingView>('main')
  const scopeTab = signal<SharingScopeTab>('container')
  const query = signal('')
  const browseOpen = signal(false)
  const staged = signal<SharingSubject[]>([])
  const stagedRole = signal<PageRole>('view')
  const stagedScope = signal<SharingScopeTab>('container')

  const stagedKeys = computed(() => new Set(staged.value.map(subjectKey)))
  const hasStagedAgents = computed(() => staged.value.some(subject => subject.kind === 'agent'))

  return {
    view,
    scopeTab,
    query,
    browseOpen,
    staged,
    stagedRole,
    stagedScope,
    stagedKeys,
    hasStagedAgents,
    reset() {
      batch(() => {
        view.value = 'main'
        scopeTab.value = 'container'
        query.value = ''
        browseOpen.value = false
        staged.value = []
        stagedRole.value = 'view'
        stagedScope.value = 'container'
      })
    },
    backToMain() {
      batch(() => {
        view.value = 'main'
        query.value = ''
        browseOpen.value = false
        staged.value = []
        stagedRole.value = 'view'
        stagedScope.value = 'container'
      })
    },
    stageSubject(subject: SharingSubject, defaultRole?: PageRole, defaultScope?: SharingScopeTab) {
      const key = subjectKey(subject)
      batch(() => {
        const current = staged.peek()
        if (current.length === 0) {
          if (defaultRole) stagedRole.value = defaultRole
          if (defaultScope) stagedScope.value = defaultScope
        }
        if (!current.some(item => subjectKey(item) === key)) {
          staged.value = [...current, subject]
        }
        query.value = ''
        browseOpen.value = false
        view.value = 'invite'
      })
    },
    unstageSubject(key: string) {
      staged.value = staged.peek().filter(item => subjectKey(item) !== key)
    },
    openInvite(scope: SharingScopeTab = 'container', defaultRole: PageRole = 'view') {
      batch(() => {
        staged.value = []
        stagedScope.value = scope
        stagedRole.value = defaultRole
        query.value = ''
        browseOpen.value = false
        view.value = 'invite'
      })
    },
    openCollaborators(tab: SharingScopeTab = 'container') {
      batch(() => {
        scopeTab.value = tab
        query.value = ''
        browseOpen.value = false
        view.value = 'collaborators'
      })
    },
    openSettings() {
      batch(() => {
        query.value = ''
        browseOpen.value = false
        view.value = 'settings'
      })
    },
    buildInvitePatch(): PageSharingUpdate | undefined {
      const items = staged.peek()
      if (items.length === 0) return undefined
      const role = stagedRole.peek()
      const target_scope = stagedScope.peek()
      return {
        upserts: items.map(subject => ({
          principal_uid: subject.principal_uid ?? null,
          group_id: subject.group_id ?? null,
          role,
          target_scope
        }))
      }
    }
  }
})
