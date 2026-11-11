import { Button, Select, SelectContent, SelectItem, SelectTrigger, SelectValue, toast } from '@ankole/uikit'
import { RiCheckLine } from '@remixicon/react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { principalUID } from '../../common/browser-context'
import { requestErrorMessage } from '../../common/request-errors'
import { contentKeys, pageAPI, type PageSharingDetail, type PageSharingExplainAction } from '../content-api'
import { ContentError, InlineLoading } from '../content-primitives'
import { AccessWaterfallView } from './access-waterfall-view'
import { SubviewHeader } from './sharing-primitives'
import type { PageSharingMutations } from './use-page-sharing'

const EXPLAIN_ACTIONS: readonly PageSharingExplainAction[] = [
  'node_view',
  'node_comment',
  'node_contribute',
  'node_edit',
  'node_manage'
]

interface CandidatePrincipal {
  uid: string
  label: string
}

export function CheckAccessView({
  pageID,
  sharing,
  canManage,
  mutations,
  onBack
}: {
  pageID: string
  sharing: PageSharingDetail
  canManage: boolean
  mutations: PageSharingMutations
  onBack(): void
}) {
  const { t } = useTranslation()
  const client = useQueryClient()
  const viewerUid = principalUID()

  const candidates = useMemo<CandidatePrincipal[]>(() => {
    const byUid = new Map<string, string>()
    if (viewerUid) {
      byUid.set(viewerUid, `${t('pod.sharing.you_subject')} (@${viewerUid})`)
    }
    for (const sub of sharing.subjects) {
      if (sub.principal_uid && !byUid.has(sub.principal_uid)) {
        byUid.set(sub.principal_uid, `${sub.name} (@${sub.principal_uid})`)
      }
    }
    for (const grant of sharing.grants) {
      if (grant.principal_uid && !byUid.has(grant.principal_uid)) {
        byUid.set(grant.principal_uid, `${grant.name} (@${grant.principal_uid})`)
      }
    }
    for (const inh of sharing.inherited) {
      if (inh.principal_uid && !byUid.has(inh.principal_uid)) {
        byUid.set(inh.principal_uid, `${inh.name} (@${inh.principal_uid})`)
      }
    }
    return [...byUid.entries()].map(([uid, label]) => ({ uid, label }))
  }, [sharing.grants, sharing.inherited, sharing.subjects, t, viewerUid])

  const [selectedUid, setSelectedUid] = useState<string>(() => candidates[0]?.uid ?? '')
  const [action, setAction] = useState<PageSharingExplainAction>('node_view')

  const activeUid = selectedUid || candidates[0]?.uid || ''
  const explainQuery = useQuery({
    queryKey: contentKeys.sharingExplain(pageID, activeUid, action),
    queryFn: ({ signal }) => pageAPI.explainSharing(pageID, activeUid, action, signal),
    enabled: Boolean(activeUid)
  })

  const actionLabels: Record<PageSharingExplainAction, string> = {
    node_view: t('pod.sharing.role_view'),
    node_comment: t('pod.sharing.role_comment'),
    node_contribute: t('pod.sharing.role_contribute'),
    node_edit: t('pod.sharing.role_edit'),
    node_manage: t('pod.sharing.role_manage')
  }

  const explain = explainQuery.data
  const canQuickGrantView =
    canManage &&
    !!explain &&
    !explain.allowed &&
    !explain.effective_actions.includes('node_view') &&
    !(
      sharing.scope_kind === 'private' &&
      sharing.subjects.find(s => s.principal_uid === explain.authority_uid)?.membership === 'guest'
    )

  return (
    <div className="flex min-h-0 flex-col">
      <SubviewHeader title={t('pod.sharing.check_access')} disabled={mutations.pending} onBack={onBack} />

      <div className="grid gap-3 overflow-y-auto px-4 pb-4">
        <div className="grid gap-2 sm:grid-cols-3">
          <div className="sm:col-span-2">
            <label id="sharing-explain-subject-label" className="mb-1 block text-xs font-medium text-fg-secondary">
              {t('pod.sharing.explain_subject')}
            </label>
            <Select value={activeUid} onValueChange={val => setSelectedUid(String(val))}>
              <SelectTrigger aria-labelledby="sharing-explain-subject-label" size="sm" className="w-full">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {candidates.map(candidate => (
                  <SelectItem key={candidate.uid} value={candidate.uid}>
                    {candidate.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <div>
            <label id="sharing-explain-action-label" className="mb-1 block text-xs font-medium text-fg-secondary">
              {t('pod.sharing.explain_action')}
            </label>
            <Select value={action} onValueChange={val => setAction(val as PageSharingExplainAction)}>
              <SelectTrigger aria-labelledby="sharing-explain-action-label" size="sm" className="w-full">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {EXPLAIN_ACTIONS.map(item => (
                  <SelectItem key={item} value={item}>
                    {actionLabels[item]}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
        </div>

        {explainQuery.isPending && <InlineLoading label={t('pod.sharing.evaluating_access')} />}
        {explainQuery.error && <ContentError error={explainQuery.error} retry={() => void explainQuery.refetch()} />}

        {explain && (
          <>
            <AccessWaterfallView explain={explain} />
            {canQuickGrantView && (
              <div className="flex items-center justify-end pt-1">
                <Button
                  type="button"
                  size="sm"
                  disabled={mutations.pending}
                  onClick={() => {
                    const targetUid = explain.authority_uid || explain.subject_uid
                    void mutations
                      .submitPatch({
                        upserts: [
                          {
                            principal_uid: targetUid,
                            role: 'view',
                            target_scope: 'container'
                          }
                        ]
                      })
                      .then(
                        () => {
                          void client.invalidateQueries({
                            queryKey: [...contentKeys.all, 'sharing', pageID, 'explain']
                          })
                          toast.success(t('pod.sharing.granted_view_toast', { uid: targetUid }))
                        },
                        err => {
                          toast.error(requestErrorMessage(err))
                        }
                      )
                  }}>
                  <RiCheckLine aria-hidden className="size-4" />
                  <span>{t('pod.sharing.grant_view_now')}</span>
                </Button>
              </div>
            )}
          </>
        )}
      </div>
    </div>
  )
}
