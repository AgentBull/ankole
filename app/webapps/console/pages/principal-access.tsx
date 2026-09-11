import { Badge, Button, Checkbox, Textarea, toast } from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import {
  ankoleWebHumanAccessControllerShowOptions,
  ankoleWebHumanAccessControllerDisableMutation,
  ankoleWebHumanAccessControllerRestoreMutation,
  ankoleWebHumanAccessControllerClearRestrictionMutation,
  ankoleWebHumanAccessControllerRetryCleanupMutation
} from '../api/generated/@tanstack/react-query.gen'
import { AccessReviewModel } from '../state/access-review-model'
import { ErrorBlock } from '../../common/error-block'
import { requestErrorMessage } from '../../common/request-errors'
import { LabeledField } from '../console-form'

export function HumanAccessSection({ uid }: { uid: string }) {
  useSignals()
  const { t } = useTranslation()
  const model = useModel(AccessReviewModel)
  const queryClient = useQueryClient()
  const access = useQuery({ ...ankoleWebHumanAccessControllerShowOptions({ path: { uid } }), refetchInterval: 15000 })
  const onSuccess = () => {
    void queryClient.invalidateQueries()
    model.confirmed.value = false
    model.approvedFingerprint.value = undefined
    model.identityVerified.value = false
    toast.success(t('console.human_access.saved'))
  }
  const onError = (error: unknown) => toast.error(requestErrorMessage(error))
  const disable = useMutation({ ...ankoleWebHumanAccessControllerDisableMutation(), onSuccess, onError })
  const restore = useMutation({ ...ankoleWebHumanAccessControllerRestoreMutation(), onSuccess, onError })
  const clear = useMutation({ ...ankoleWebHumanAccessControllerClearRestrictionMutation(), onSuccess, onError })
  const retry = useMutation({ ...ankoleWebHumanAccessControllerRetryCleanupMutation(), onSuccess, onError })
  const state = access.data
  const pending = disable.isPending || restore.isPending || clear.isPending || retry.isPending
  const reasonBody = () => ({ reason: model.reason.value.trim(), operation_id: crypto.randomUUID() })
  const activeRestrictions = state?.restrictions.filter(item => !item.cleared_at) ?? []
  return (
    <section className="grid gap-5 border-b border-border pb-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h3 className="text-lg font-semibold">{t('console.human_access.title')}</h3>
        {state ? (
          <Badge variant={state.status === 'active' ? 'success' : 'outline'}>
            {t(`console.status.${state.status}`)}
          </Badge>
        ) : null}
      </div>
      <p className="text-sm text-muted-foreground">{t('console.human_access.disable_hint')}</p>
      <ErrorBlock error={access.error} />
      {access.isLoading ? <p role="status">{t('common.loading')}</p> : null}
      {state ? (
        <>
          <LabeledField label={t('console.human_access.reason')} required>
            <Textarea
              maxLength={2000}
              value={model.reason.value}
              onChange={e => {
                model.reason.value = e.target.value
              }}
              rows={2}
            />
          </LabeledField>
          {state.status === 'active' ? (
            <>
              <label className="flex items-start gap-3 text-sm">
                <Checkbox
                  checked={model.confirmed.value}
                  onCheckedChange={checked => {
                    model.confirmed.value = checked === true
                  }}
                />
                <span>{t('console.human_access.disable_confirm')}</span>
              </label>
              <Button
                className="justify-self-start"
                variant="destructive"
                disabled={pending || !model.hasReason.value || !model.confirmed.value}
                onClick={() => disable.mutate({ path: { uid }, body: reasonBody() })}>
                {t('console.human_access.disable')}
              </Button>
            </>
          ) : (
            <>
              <p className="text-sm text-muted-foreground">{t('console.human_access.restore_hint')}</p>
              {activeRestrictions.map(item => (
                <div key={item.id} className="grid gap-3 border border-border p-4 sm:grid-cols-[1fr_auto]">
                  <div className="grid gap-1 text-sm">
                    <span className="font-medium">{item.source}</span>
                    <span>{item.reason}</span>
                    <span className="text-xs text-muted-foreground">
                      {item.recovery_verified_at ?? item.inserted_at}
                    </span>
                  </div>
                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    disabled={
                      pending || !model.hasReason.value || (item.source !== 'manual' && !item.recovery_verified_at)
                    }
                    onClick={() => clear.mutate({ path: { uid, restriction_id: item.id }, body: reasonBody() })}>
                    {t('console.human_access.clear')}
                  </Button>
                </div>
              ))}
              {activeRestrictions.some(item => item.source !== 'manual') ? (
                <p className="text-sm text-muted-foreground">{t('console.human_access.provider_check')}</p>
              ) : null}
              <details className="border border-border p-4" open>
                <summary className="cursor-pointer text-sm font-medium">
                  {t('console.human_access.permissions')}
                </summary>
                <p className="my-3 text-sm text-muted-foreground">{t('console.human_access.permissions_hint')}</p>
                <div className="grid gap-3 text-sm">
                  {state.permission_review.permissions.groups.map(group => (
                    <div key={group.id}>
                      <span className="font-medium">
                        {group.name} · {group.kind}
                      </span>
                      {group.condition ? (
                        <pre className="overflow-auto text-xs whitespace-pre-wrap">
                          {JSON.stringify(group.condition, null, 2)}
                        </pre>
                      ) : null}
                    </div>
                  ))}
                  {state.permission_review.permissions.grants.map(grant => (
                    <div key={grant.id} className="border-t border-border pt-2">
                      <code>
                        {grant.resource_pattern} · {grant.action}
                      </code>
                      <p className="text-xs text-muted-foreground">{grant.principal_uid ?? grant.group_id}</p>
                      {grant.condition ? (
                        <pre className="overflow-auto text-xs whitespace-pre-wrap">
                          {JSON.stringify(grant.condition, null, 2)}
                        </pre>
                      ) : null}
                    </div>
                  ))}
                </div>
              </details>
              <label className="flex items-start gap-3 text-sm">
                <Checkbox
                  checked={model.identityVerified.value}
                  onCheckedChange={checked => {
                    model.identityVerified.value = checked === true
                  }}
                />
                <span>{t('console.human_access.identity_confirm')}</span>
              </label>
              <label className="flex items-start gap-3 text-sm">
                <Checkbox
                  checked={model.approvedFingerprint.value === state.permission_review.fingerprint}
                  onCheckedChange={checked => {
                    model.approvedFingerprint.value = checked === true ? state.permission_review.fingerprint : undefined
                  }}
                />
                <span>{t('console.human_access.permissions_confirm')}</span>
              </label>
              <Button
                className="justify-self-start"
                disabled={
                  pending ||
                  !model.hasReason.value ||
                  model.approvedFingerprint.value !== state.permission_review.fingerprint ||
                  !model.identityVerified.value ||
                  activeRestrictions.length > 0
                }
                onClick={() =>
                  restore.mutate({
                    path: { uid },
                    body: {
                      ...reasonBody(),
                      identity_verified: true,
                      review_fingerprint: model.approvedFingerprint.value!
                    }
                  })
                }>
                {t('console.human_access.restore')}
              </Button>
            </>
          )}
          <details className="border-t border-border pt-4">
            <summary className="cursor-pointer text-sm font-medium">{t('console.human_access.work')}</summary>
            <p className="my-3 text-sm text-muted-foreground">{t('console.human_access.work_hint')}</p>
            <div className="grid gap-2 text-sm">
              {state.cleanup_jobs.map(job => (
                <p key={job.id}>
                  #{job.id} · {job.state} · {job.attempt}/{job.max_attempts}
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
                  <span>
                    {work.kind} · {work.status} · {work.agent_uid}
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
                    {item.action} · {item.source}
                  </span>
                  <p>{item.reason}</p>
                  <p className="text-xs text-muted-foreground">
                    {item.actor_uid} · {item.inserted_at}
                  </p>
                </div>
              ))}
            </div>
          </details>
        </>
      ) : null}
    </section>
  )
}
