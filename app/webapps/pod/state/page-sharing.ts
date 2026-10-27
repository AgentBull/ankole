import { batch, createModel, signal } from '@preact/signals-react'
import type { PodPageSharingResponse } from '../api/generated/types.gen'
import type { PageRole, PageSharing } from '../content-api'

// Ordinary rules send a role. Advanced rules preserve their exact stored actions.
type SharingGrant = Omit<PodPageSharingResponse['grants'][number], 'actions'> & {
  actions?: PodPageSharingResponse['grants'][number]['actions']
}
type SharingDraft = Omit<PodPageSharingResponse, 'grants'> & { grants: SharingGrant[] }

const roleActionCount: Record<PageRole, number> = { view: 1, contribute: 2, edit: 3, manage: 4 }

export function isAdvancedSharingRule(grant: SharingGrant): boolean {
  // The server projects the highest action as the role. A full role contains each lower action.
  return (
    !!grant.source_page_id ||
    (grant.condition ?? 'true') !== 'true' ||
    (grant.actions !== undefined && grant.actions.length !== roleActionCount[grant.role])
  )
}

export const PageSharingModel = createModel(() => {
  const draft = signal<SharingDraft>()
  const conflictReloaded = signal(false)
  return {
    draft,
    conflictReloaded,
    replace(source: PodPageSharingResponse) {
      batch(() => {
        draft.value = source
        conflictReloaded.value = false
      })
    },
    keepDraft(version: string) {
      const current = draft.peek()
      if (!current) return
      batch(() => {
        draft.value = { ...current, sharing_version: version }
        conflictReloaded.value = true
      })
    },
    inherit(inherit_permissions: boolean) {
      const current = draft.peek()
      if (current) draft.value = { ...current, inherit_permissions }
    },
    add(grant: SharingGrant) {
      const current = draft.peek()
      if (current) {
        const next = { ...grant, target_scope: grant.target_scope ?? 'container' }
        draft.value = {
          ...current,
          grants: [...current.grants.filter(item => ruleKey(item) !== ruleKey(next)), next]
        }
      }
    },
    update(index: number, attrs: Partial<SharingGrant>) {
      const current = draft.peek()
      if (current) {
        draft.value = {
          ...current,
          grants: current.grants.map((grant, i) => {
            if (i !== index) return grant
            const changed = { ...grant, ...attrs }
            if (attrs.role && attrs.role !== grant.role) delete changed.actions
            return changed
          })
        }
      }
    },
    remove(index: number) {
      const current = draft.peek()
      if (current) draft.value = { ...current, grants: current.grants.filter((_, i) => i !== index) }
    },
    body(): PageSharing | undefined {
      const current = draft.peek()
      if (!current) return undefined
      return {
        sharing_version: current.sharing_version,
        inherit_permissions: current.inherit_permissions,
        grants: current.grants.map(grant => {
          const { principal_uid, group_id, role, target_scope, source_page_id, source_action, condition, actions } =
            grant
          return {
            principal_uid,
            group_id,
            target_scope: target_scope ?? 'container',
            source_page_id,
            source_action,
            condition: condition?.trim() || 'true',
            ...(actions && isAdvancedSharingRule(grant) ? { actions } : { role })
          }
        })
      }
    }
  }
})

function ruleKey(grant: SharingGrant): string {
  return JSON.stringify([
    grant.principal_uid ?? null,
    grant.group_id ?? null,
    grant.source_page_id ?? null,
    grant.source_action ?? null,
    grant.target_scope ?? 'container',
    grant.condition?.trim() || 'true'
  ])
}
