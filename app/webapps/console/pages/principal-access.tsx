import { useMutation, useQuery } from '../tenant-context'
import { uuidV4 } from '@agentbull/active-support'
import { ActorLabel } from '../actor-label'
import { Badge, Button, Textarea, toast } from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'

import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import {
  getHumanAccessOptions,
  recoverHumanPodAdminMutation,
  restoreHumanAccessMutation
} from '../api/v2/generated/@tanstack/react-query.gen'
import type { GetHumanAccessResponse } from '../api/v2/generated/types.gen'
import { ErrorBlock } from '../../common/error-block'
import { humanizeTechnicalLabel } from '../../common/humanize-technical-label'
import { requestErrorMessage } from '../../common/request-errors'
import { LabeledField } from '../console-form'
import { AgentLink } from '../console-list-page'
import { formatConsoleDate } from '../console-primitives'
import { LIST_REFRESH_MS } from '../refresh-intervals'
import { AccessReviewModel } from '../state/access-review-model'

type RestrictionItem = GetHumanAccessResponse['restrictions'][number]

export function HumanAccessSection({ uid }: { uid: string }) {
  useSignals()
  const { t } = useTranslation()
  const restoreModel = useModel(AccessReviewModel)
  const [adminRecoveryReason, setAdminRecoveryReason] = useState('')

  const access = useQuery({ ...getHumanAccessOptions({ path: { uid } }), refetchInterval: LIST_REFRESH_MS })
  const state = access.data

  const onError = (error: unknown) => toast.error(requestErrorMessage(error))
  const restore = useMutation({
    ...restoreHumanAccessMutation(),
    onSuccess: () => {
      restoreModel.reason.value = ''
      toast.success(t('console.human_access.saved'))
    },
    onError
  })
  const recoverAdmin = useMutation({
    ...recoverHumanPodAdminMutation(),
    onSuccess: () => {
      setAdminRecoveryReason('')
      toast.success(t('console.human_access.saved'))
    },
    onError
  })

  const pending = restore.isPending || recoverAdmin.isPending
  const activeRestrictions = state?.restrictions.filter(item => !item.cleared_at) ?? []

  return (
    <section className="grid gap-5 border-b border-border-subtle pb-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h3 className="title-section">{t('console.human_access.title')}</h3>
        {state ? (
          <Badge variant={state.status === 'active' ? 'success' : 'outline'}>
            {t(`console.status.${state.status}`, { defaultValue: humanizeTechnicalLabel(state.status) })}
          </Badge>
        ) : null}
      </div>
      <p className="text-sm text-fg-secondary">{t('console.human_access.break_glass_hint')}</p>
      <ErrorBlock error={access.error} />
      {access.isLoading ? <p role="status">{t('common.loading')}</p> : null}
      {state ? (
        <>
          {state.status !== 'active' ? (
            <div className="grid gap-4">
              <p className="text-sm text-fg-secondary">{t('console.human_access.restore_hint')}</p>
              {activeRestrictions.map(item => (
                <RestrictionCard key={item.id} restriction={item} />
              ))}

              <form
                aria-label={t('console.human_access.restore')}
                className="grid gap-4 border border-border-subtle bg-page p-4"
                onSubmit={event => {
                  event.preventDefault()
                  restore.mutate({
                    path: { uid },
                    body: { data: { reason: restoreModel.reason.value.trim(), operation_id: uuidV4() } }
                  })
                }}>
                <LabeledField label={t('console.human_access.reason')} required>
                  <Textarea
                    required
                    maxLength={2000}
                    rows={2}
                    value={restoreModel.reason.value}
                    onChange={event => {
                      restoreModel.reason.value = event.target.value
                    }}
                  />
                </LabeledField>
                <Button
                  className="justify-self-start"
                  disabled={pending || !restoreModel.reason.value.trim()}
                  type="submit">
                  {t('console.human_access.restore')}
                </Button>
              </form>
            </div>
          ) : (
            <form
              aria-label={t('console.human_access.recover_pod_admin')}
              className="grid gap-4 border border-border-subtle bg-page p-4"
              onSubmit={event => {
                event.preventDefault()
                recoverAdmin.mutate({
                  path: { uid },
                  body: { data: { reason: adminRecoveryReason.trim(), operation_id: uuidV4() } }
                })
              }}>
              <div className="grid gap-1">
                <h4 className="text-sm font-medium">{t('console.human_access.recover_pod_admin')}</h4>
                <p className="text-xs leading-5 text-fg-secondary">
                  {t('console.human_access.recover_pod_admin_hint')}
                </p>
              </div>
              <LabeledField label={t('console.human_access.reason')} required>
                <Textarea
                  required
                  maxLength={2000}
                  rows={2}
                  value={adminRecoveryReason}
                  onChange={event => setAdminRecoveryReason(event.target.value)}
                />
              </LabeledField>
              <Button className="justify-self-start" disabled={pending || !adminRecoveryReason.trim()} type="submit">
                {t('console.human_access.recover_pod_admin')}
              </Button>
            </form>
          )}

          <details className="border-t border-border-subtle pt-4">
            <summary className="cursor-pointer text-sm font-medium">{t('console.human_access.work')}</summary>
            <p className="my-3 text-sm text-fg-secondary">{t('console.human_access.work_hint')}</p>
            <div className="grid gap-2 text-sm">
              {state.cleanup_jobs.map(job => (
                <p key={job.id}>
                  #{job.id} ·{' '}
                  {t(`console.human_access.cleanup_state_${job.state}`, {
                    defaultValue: humanizeTechnicalLabel(job.state)
                  })}{' '}
                  · {job.attempt}/{job.max_attempts}
                </p>
              ))}
            </div>
            <div className="mt-3 grid gap-2">
              {state.work.map(work => (
                <div key={`${work.kind}:${work.id}`} className="grid gap-1 border-b border-border-subtle py-2 text-sm">
                  <span className="flex flex-wrap items-center gap-x-2 gap-y-1">
                    <span>{humanizeTechnicalLabel(work.kind)}</span>
                    <span aria-hidden>·</span>
                    <span>
                      {t(`console.status.${work.status}`, { defaultValue: humanizeTechnicalLabel(work.status) })}
                    </span>
                    {work.agent_uid ? (
                      <>
                        <span aria-hidden>·</span>
                        <AgentLink uid={work.agent_uid} />
                      </>
                    ) : null}
                  </span>
                  <code className="text-xs break-all text-fg-secondary">{work.id}</code>
                </div>
              ))}
            </div>
          </details>

          <details className="border-t border-border-subtle pt-4">
            <summary className="cursor-pointer text-sm font-medium">{t('console.human_access.history')}</summary>
            <div className="mt-3 grid gap-3">
              {state.history.map(item => {
                const detailsText =
                  item.details && typeof item.details === 'object' && Object.keys(item.details).length > 0
                    ? JSON.stringify(item.details)
                    : null
                return (
                  <div key={item.id} className="grid gap-1 border-b border-border-subtle pb-3 text-sm">
                    <span>
                      {humanizeTechnicalLabel(item.action)} · {humanizeTechnicalLabel(item.source)}
                    </span>
                    <p>{item.reason}</p>
                    {detailsText ? <code className="text-xs break-all text-fg-secondary">{detailsText}</code> : null}
                    <p className="text-xs text-fg-secondary">
                      <ActorLabel actor={item.actor} /> · {formatConsoleDate(item.inserted_at)}
                    </p>
                  </div>
                )
              })}
            </div>
          </details>
        </>
      ) : null}
    </section>
  )
}

function RestrictionCard({ restriction }: { restriction: RestrictionItem }) {
  return (
    <div className="grid gap-3 border border-border-subtle bg-page p-4">
      <div className="flex flex-wrap items-start justify-between gap-2 text-sm">
        <div className="grid gap-1">
          <div className="flex flex-wrap items-center gap-2">
            <span className="font-medium">{humanizeTechnicalLabel(restriction.source)}</span>
            {restriction.disposition ? (
              <Badge variant="outline">{humanizeTechnicalLabel(restriction.disposition)}</Badge>
            ) : null}
          </div>
          <span>{restriction.reason}</span>
        </div>
        <span className="text-xs text-fg-secondary">
          {formatConsoleDate(restriction.recovery_verified_at ?? restriction.inserted_at)}
        </span>
      </div>
    </div>
  )
}
