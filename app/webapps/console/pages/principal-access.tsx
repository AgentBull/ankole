import { useMutation, useQuery } from '../tenant-context'
import { isRecord, uuidV4 } from '@agentbull/active-support'
import { ActorLabel } from '../actor-label'
import {
  Badge,
  Button,
  Checkbox,
  Dialog,
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  Textarea,
  toast
} from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'

import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import {
  clearHumanAccessRestrictionMutation,
  disableHumanAccessMutation,
  getHumanAccessOptions,
  listPrincipalGroupsOptions,
  listPrincipalsOptions,
  restoreHumanAccessMutation,
  retryHumanWorkCleanupMutation
} from '../api/v2/generated/@tanstack/react-query.gen'
import type { GetHumanAccessResponse } from '../api/v2/generated/types.gen'
import { fromDocument } from '../api/json-api'
import { ErrorBlock } from '../../common/error-block'
import { humanizeTechnicalLabel } from '../../common/humanize-technical-label'
import { requestErrorMessage } from '../../common/request-errors'
import { DiscardConfirmDialog, LabeledField, useDialogDiscardGuard } from '../console-form'
import { AgentLink } from '../console-list-page'
import { formatConsoleDate } from '../console-primitives'
import { AccessReviewModel } from '../state/access-review-model'
import { principalGroupDisplayName } from '../state/principal-group-text'
import { principalLabel } from '../state/principal-label'

type RestrictionItem = GetHumanAccessResponse['restrictions'][number]

/** Summarizes a group or grant condition without dumping raw JSON blocks or `"true"` noise. */
export function formatConditionSummary(condition: unknown): string | null {
  if (condition == null || condition === true || condition === 'true' || condition === '') return null
  if (typeof condition === 'string') return condition.trim() || null
  if (typeof condition === 'number' || typeof condition === 'boolean') return String(condition)
  if (Array.isArray(condition)) {
    const parts = condition.map(item => formatConditionSummary(item)).filter((item): item is string => Boolean(item))
    return parts.length > 0 ? parts.join(', ') : null
  }
  if (isRecord(condition)) {
    const entries = Object.entries(condition)
      .map(([key, value]) => {
        const formatted = formatConditionSummary(value)
        if (formatted === null) return `${key}: true`
        return `${key}: ${formatted}`
      })
      .filter(Boolean)
    return entries.length > 0 ? entries.join(' · ') : null
  }
  return String(condition)
}

export function HumanAccessSection({ uid }: { uid: string }) {
  useSignals()
  const { t } = useTranslation()
  const restoreModel = useModel(AccessReviewModel)
  const [disableDisposition, setDisableDisposition] = useState<'suspended' | 'offboarded' | null>(null)
  const [disableReason, setDisableReason] = useState('')
  const [disableConfirmed, setDisableConfirmed] = useState(false)

  const access = useQuery({ ...getHumanAccessOptions({ path: { uid } }), refetchInterval: 15000 })
  const state = access.data

  const groups = useQuery({
    ...listPrincipalGroupsOptions(),
    select: document => fromDocument(document),
    enabled: Boolean(state && state.status !== 'active')
  })
  const principals = useQuery({
    ...listPrincipalsOptions({ query: { include_disabled: true } }),
    select: document => fromDocument(document),
    enabled: Boolean(state && state.status !== 'active')
  })

  const groupByID = new Map((groups.data ?? []).map(group => [group.id, group]))
  const principalByUID = new Map((principals.data ?? []).map(principal => [principal.id, principal]))

  const onError = (error: unknown) => toast.error(requestErrorMessage(error))
  const disable = useMutation({
    ...disableHumanAccessMutation(),
    onSuccess: () => {
      setDisableDisposition(null)
      setDisableReason('')
      setDisableConfirmed(false)
      toast.success(t('console.human_access.saved'))
    },
    onError
  })
  const restore = useMutation({
    ...restoreHumanAccessMutation(),
    onSuccess: () => {
      restoreModel.reason.value = ''
      restoreModel.approvedFingerprint.value = undefined
      restoreModel.identityVerified.value = false
      toast.success(t('console.human_access.saved'))
    },
    onError
  })
  const retry = useMutation({
    ...retryHumanWorkCleanupMutation(),
    onSuccess: () => toast.success(t('console.human_access.saved')),
    onError
  })

  const openDisableDialog = (disposition: 'suspended' | 'offboarded') => {
    setDisableReason('')
    setDisableConfirmed(false)
    setDisableDisposition(disposition)
  }

  const disableDialogDirty = Boolean(disableReason.trim()) || disableConfirmed
  const disableGuard = useDialogDiscardGuard({
    dirty: disableDialogDirty,
    onOpenChange: open => {
      if (!open) {
        setDisableDisposition(null)
        setDisableReason('')
        setDisableConfirmed(false)
      }
    },
    pending: disable.isPending
  })

  const pending = disable.isPending || restore.isPending || retry.isPending
  const activeRestrictions = state?.restrictions.filter(item => !item.cleared_at) ?? []
  const isOffboarded =
    state?.status === 'offboarded' || activeRestrictions.some(item => item.disposition === 'offboarded')
  const canSuspend = state?.status === 'active'
  const canOffboard = Boolean(state && !isOffboarded)

  return (
    <section className="grid gap-5 border-b border-border pb-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h3 className="text-lg font-semibold">{t('console.human_access.title')}</h3>
        {state ? (
          <Badge variant={state.status === 'active' ? 'success' : 'outline'}>
            {t(`console.status.${state.status}`, { defaultValue: humanizeTechnicalLabel(state.status) })}
          </Badge>
        ) : null}
      </div>
      <p className="text-sm text-muted-foreground">{t('console.human_access.disable_hint')}</p>
      <ErrorBlock error={access.error} />
      {access.isLoading ? <p role="status">{t('common.loading')}</p> : null}
      {state ? (
        <>
          {canSuspend || canOffboard ? (
            <div className="grid gap-3 sm:grid-cols-2">
              {canSuspend ? (
                <div className="grid content-between gap-3 border border-border bg-card p-4">
                  <div className="grid gap-1">
                    <h4 className="text-sm font-medium">{t('pod.settings.suspend')}</h4>
                    <p className="text-xs leading-5 text-muted-foreground">{t('pod.settings.suspended_description')}</p>
                  </div>
                  <Button
                    className="justify-self-start"
                    disabled={pending}
                    type="button"
                    variant="destructive"
                    onClick={() => openDisableDialog('suspended')}>
                    {t('pod.settings.suspend')}
                  </Button>
                </div>
              ) : null}
              {canOffboard ? (
                <div className="grid content-between gap-3 border border-border bg-card p-4">
                  <div className="grid gap-1">
                    <h4 className="text-sm font-medium">{t('pod.settings.offboard')}</h4>
                    <p className="text-xs leading-5 text-muted-foreground">
                      {t('pod.settings.offboarded_description')}
                    </p>
                  </div>
                  <Button
                    className="justify-self-start"
                    disabled={pending}
                    type="button"
                    variant="destructive"
                    onClick={() => openDisableDialog('offboarded')}>
                    {t('pod.settings.offboard')}
                  </Button>
                </div>
              ) : null}
            </div>
          ) : null}

          {state.status !== 'active' ? (
            <div className="grid gap-4">
              <p className="text-sm text-muted-foreground">{t('console.human_access.restore_hint')}</p>
              {activeRestrictions.map(item => (
                <RestrictionClearCard key={item.id} disabled={pending} restriction={item} uid={uid} />
              ))}
              {activeRestrictions.some(item => item.source !== 'manual') ? (
                <p className="text-sm text-muted-foreground">{t('console.human_access.provider_check')}</p>
              ) : null}

              <div className="grid gap-4 border border-border bg-card p-4">
                <details className="border border-border p-4" open>
                  <summary className="cursor-pointer text-sm font-medium">
                    {t('console.human_access.permissions')}
                  </summary>
                  <p className="my-3 text-sm text-muted-foreground">{t('console.human_access.permissions_hint')}</p>
                  <div className="grid gap-3 text-sm">
                    {state.permission_review.permissions.groups.map(group => {
                      const fullGroup = groupByID.get(group.id)
                      const groupLabel = fullGroup
                        ? principalGroupDisplayName(t, fullGroup)
                        : t(`console.principal_groups.builtin_${group.name}_name`, { defaultValue: group.name })
                      const conditionText = formatConditionSummary(group.condition)
                      return (
                        <div key={group.id} className="grid gap-1">
                          <div className="flex flex-wrap items-center gap-2">
                            <span className="font-medium">{groupLabel}</span>
                            <Badge variant="outline">
                              {t(`console.principal_groups.kind_${group.kind}`, {
                                defaultValue: humanizeTechnicalLabel(group.kind)
                              })}
                            </Badge>
                          </div>
                          {conditionText ? (
                            <p className="text-xs text-muted-foreground">
                              {t('console.permission_grants.condition')}:{' '}
                              <code className="break-all">{conditionText}</code>
                            </p>
                          ) : null}
                        </div>
                      )
                    })}
                    {state.permission_review.permissions.grants.map(grant => {
                      const grantPrincipal = grant.principal_uid ? principalByUID.get(grant.principal_uid) : undefined
                      const grantGroup = grant.group_id ? groupByID.get(grant.group_id) : undefined
                      const ownerDisplay = grant.principal_uid
                        ? grantPrincipal
                          ? principalLabel(grantPrincipal)
                          : grant.principal_uid
                        : grant.group_id
                          ? grantGroup
                            ? principalGroupDisplayName(t, grantGroup)
                            : grant.group_id
                          : '—'
                      const conditionText = formatConditionSummary(grant.condition)
                      return (
                        <div key={grant.id} className="grid gap-1 border-t border-border pt-2">
                          <div className="flex flex-wrap items-center gap-2">
                            <code className="text-xs">{grant.resource_pattern}</code>
                            <Badge variant="secondary">{grant.action}</Badge>
                          </div>
                          <p className="text-xs text-muted-foreground">{ownerDisplay}</p>
                          {conditionText ? (
                            <p className="text-xs text-muted-foreground">
                              {t('console.permission_grants.condition')}:{' '}
                              <code className="break-all">{conditionText}</code>
                            </p>
                          ) : null}
                        </div>
                      )
                    })}
                  </div>
                </details>

                <label className="flex items-start gap-3 text-sm">
                  <Checkbox
                    checked={restoreModel.identityVerified.value}
                    onCheckedChange={checked => {
                      restoreModel.identityVerified.value = checked === true
                    }}
                  />
                  <span>{t('console.human_access.identity_confirm')}</span>
                </label>
                <label className="flex items-start gap-3 text-sm">
                  <Checkbox
                    checked={restoreModel.approvedFingerprint.value === state.permission_review.fingerprint}
                    onCheckedChange={checked => {
                      restoreModel.approvedFingerprint.value =
                        checked === true ? state.permission_review.fingerprint : undefined
                    }}
                  />
                  <span>{t('console.human_access.permissions_confirm')}</span>
                </label>
                <LabeledField label={t('console.human_access.reason')} required>
                  <Textarea
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
                  disabled={
                    pending ||
                    !restoreModel.hasReason.value ||
                    restoreModel.approvedFingerprint.value !== state.permission_review.fingerprint ||
                    !restoreModel.identityVerified.value ||
                    activeRestrictions.length > 0
                  }
                  type="button"
                  onClick={() =>
                    restore.mutate({
                      path: { uid },
                      body: {
                        data: {
                          reason: restoreModel.reason.value.trim(),
                          operation_id: uuidV4(),
                          identity_verified: true,
                          review_fingerprint: restoreModel.approvedFingerprint.value!
                        }
                      }
                    })
                  }>
                  {t('console.human_access.restore')}
                </Button>
              </div>
            </div>
          ) : null}

          <details className="border-t border-border pt-4">
            <summary className="cursor-pointer text-sm font-medium">{t('console.human_access.work')}</summary>
            <p className="my-3 text-sm text-muted-foreground">{t('console.human_access.work_hint')}</p>
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
            <Button
              type="button"
              size="sm"
              variant="outline"
              className="my-3"
              disabled={pending}
              onClick={() => retry.mutate({ path: { uid } })}>
              {t('console.human_access.retry_cleanup')}
            </Button>
            <div className="grid gap-2">
              {state.work.map(work => (
                <div key={`${work.kind}:${work.id}`} className="grid gap-1 border-b border-border py-2 text-sm">
                  <span className="flex flex-wrap items-center gap-x-2 gap-y-1">
                    <span>{humanizeTechnicalLabel(work.kind)}</span>
                    <span aria-hidden>·</span>
                    <span>
                      {t(`console.status.${work.status}`, { defaultValue: humanizeTechnicalLabel(work.status) })}
                    </span>
                    <span aria-hidden>·</span>
                    <AgentLink uid={work.agent_uid} />
                  </span>
                  <code className="text-xs break-all text-muted-foreground">{work.id}</code>
                </div>
              ))}
            </div>
          </details>

          <details className="border-t border-border pt-4">
            <summary className="cursor-pointer text-sm font-medium">{t('console.human_access.history')}</summary>
            <div className="mt-3 grid gap-3">
              {state.history.map(item => (
                <div key={item.id} className="grid gap-1 border-b border-border pb-3 text-sm">
                  <span>
                    {humanizeTechnicalLabel(item.action)} · {humanizeTechnicalLabel(item.source)}
                  </span>
                  <p>{item.reason}</p>
                  <p className="text-xs text-muted-foreground">
                    <ActorLabel actor={item.actor} /> · {formatConsoleDate(item.inserted_at)}
                  </p>
                </div>
              ))}
            </div>
          </details>
        </>
      ) : null}

      <Dialog open={disableDisposition !== null} onOpenChange={disableGuard.requestOpenChange}>
        <DialogContent closeLabel={t('common.close')} showCloseButton={!disable.isPending}>
          <DialogHeader>
            <DialogTitle>
              {disableDisposition === 'offboarded' ? t('pod.settings.offboard') : t('pod.settings.suspend')}
            </DialogTitle>
            <DialogDescription>
              {disableDisposition === 'offboarded'
                ? t('pod.settings.offboarded_description')
                : t('pod.settings.suspended_description')}
            </DialogDescription>
          </DialogHeader>
          <div className="grid gap-4">
            <LabeledField label={t('console.human_access.reason')} required>
              <Textarea
                maxLength={2000}
                rows={3}
                value={disableReason}
                onChange={event => setDisableReason(event.target.value)}
              />
            </LabeledField>
            <label className="flex items-start gap-3 text-sm">
              <Checkbox checked={disableConfirmed} onCheckedChange={checked => setDisableConfirmed(checked === true)} />
              <span>{t('console.human_access.disable_confirm')}</span>
            </label>
          </div>
          <DialogFooter>
            <DialogClose render={<Button disabled={disable.isPending} variant="outline" />}>
              {t('common.cancel')}
            </DialogClose>
            <Button
              disabled={disable.isPending || !disableReason.trim() || !disableConfirmed || !disableDisposition}
              type="button"
              variant="destructive"
              onClick={() =>
                disableDisposition &&
                disable.mutate({
                  path: { uid },
                  body: {
                    data: {
                      reason: disableReason.trim(),
                      operation_id: uuidV4(),
                      disposition: disableDisposition
                    }
                  }
                })
              }>
              {disableDisposition === 'offboarded' ? t('pod.settings.offboard') : t('pod.settings.suspend')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
      <DiscardConfirmDialog
        open={disableGuard.confirming}
        onDiscard={disableGuard.confirmDiscard}
        onKeep={disableGuard.keepEditing}
      />
    </section>
  )
}

function RestrictionClearCard({
  disabled,
  restriction,
  uid
}: {
  disabled: boolean
  restriction: RestrictionItem
  uid: string
}) {
  const { t } = useTranslation()
  const [reason, setReason] = useState('')
  const clear = useMutation({
    ...clearHumanAccessRestrictionMutation(),
    onSuccess: () => {
      setReason('')
      toast.success(t('console.human_access.saved'))
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const pending = disabled || clear.isPending
  const blockedByProvider = restriction.source !== 'manual' && !restriction.recovery_verified_at

  return (
    <div className="grid gap-3 border border-border bg-card p-4">
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
        <span className="text-xs text-muted-foreground">
          {formatConsoleDate(restriction.recovery_verified_at ?? restriction.inserted_at)}
        </span>
      </div>
      <div className="grid gap-3 sm:grid-cols-[1fr_auto] sm:items-end">
        <LabeledField label={t('console.human_access.reason')} required>
          <Textarea
            disabled={blockedByProvider}
            maxLength={2000}
            rows={2}
            value={reason}
            onChange={event => setReason(event.target.value)}
          />
        </LabeledField>
        <Button
          disabled={pending || !reason.trim() || blockedByProvider}
          size="sm"
          type="button"
          variant="outline"
          onClick={() =>
            clear.mutate({
              path: { uid, restriction_id: restriction.id },
              body: { data: { reason: reason.trim(), operation_id: uuidV4() } }
            })
          }>
          {t('console.human_access.clear')}
        </Button>
      </div>
    </div>
  )
}
