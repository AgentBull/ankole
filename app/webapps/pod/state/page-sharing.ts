import { batch, createModel, signal } from '@preact/signals-react'
import type { PodPageSharingResponse } from '../api/generated/types.gen'
import type { PageSharing } from '../content-api'

type SharingGrant = PodPageSharingResponse['grants'][number]

export const PageSharingModel = createModel(() => {
  const draft = signal<PodPageSharingResponse>()
  const conflictReloaded = signal(false)
  return {
    draft,
    conflictReloaded,
    initialize(source: PodPageSharingResponse) {
      if (!draft.peek()) draft.value = source
    },
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
        draft.value = {
          ...current,
          grants: [...current.grants.filter(item => ruleKey(item) !== ruleKey(grant)), grant]
        }
      }
    },
    update(index: number, attrs: Partial<SharingGrant>) {
      const current = draft.peek()
      if (current) {
        draft.value = {
          ...current,
          grants: current.grants.map((grant, i) => (i === index ? { ...grant, ...attrs } : grant))
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
        grants: current.grants.map(
          ({ principal_uid, group_id, role, target_scope, source_page_id, source_action, condition }) => ({
            principal_uid,
            group_id,
            role,
            target_scope: target_scope ?? 'container',
            source_page_id,
            source_action,
            condition: condition?.trim() || 'true'
          })
        )
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
