import { Badge, Button, Checkbox, Textarea, toast } from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import {
  ankoleWebDirectoryAccessControllerShowOptions,
  ankoleWebDirectoryAccessControllerApproveMutation,
  ankoleWebDirectoryAccessControllerReviewEventMutation
} from '../api/generated/@tanstack/react-query.gen'
import { AccessReviewModel } from '../state/access-review-model'
import { ErrorBlock } from '../../common/error-block'
import { requestErrorMessage } from '../../common/request-errors'
import { LabeledField } from '../console-form'

export function DirectoryAccessSection({ providerID }: { providerID: string }) {
  useSignals()
  const { t } = useTranslation()
  const model = useModel(AccessReviewModel)
  const queryClient = useQueryClient()
  const directory = useQuery({
    ...ankoleWebDirectoryAccessControllerShowOptions({ path: { provider_id: providerID } }),
    refetchInterval: 15000
  })
  const onSuccess = () => {
    void queryClient.invalidateQueries()
    model.approvedFingerprint.value = undefined
    toast.success(t('console.human_access.saved'))
  }
  const onError = (error: unknown) => toast.error(requestErrorMessage(error))
  const approve = useMutation({ ...ankoleWebDirectoryAccessControllerApproveMutation(), onSuccess, onError })
  const review = useMutation({ ...ankoleWebDirectoryAccessControllerReviewEventMutation(), onSuccess, onError })
  const snapshot = directory.data?.snapshot
  const pending = approve.isPending || review.isPending
  const confirmed = Boolean(
    snapshot?.snapshot_fingerprint && model.approvedFingerprint.value === snapshot.snapshot_fingerprint
  )
  return (
    <section className="grid gap-4 border-t border-border pt-6">
      <h3 className="text-lg font-semibold">{t('console.directory_access.title')}</h3>
      <p className="text-sm text-muted-foreground">{t('console.directory_access.hint')}</p>
      <ErrorBlock error={directory.error} />
      {directory.isLoading ? <p role="status">{t('common.loading')}</p> : null}
      {snapshot ? (
        <>
          <div className="flex flex-wrap gap-3 text-sm">
            <Badge variant="outline">{snapshot.status}</Badge>
            <span>{snapshot.last_success_at ?? t('console.directory_access.no_snapshot')}</span>
          </div>
          {snapshot.last_error ? (
            <p className="text-sm" role="status">
              {snapshot.last_error}
            </p>
          ) : null}
          <p className="text-sm">
            {t('console.directory_access.counts', {
              members: snapshot.member_uids.length,
              missing: snapshot.missing_uids.length
            })}
          </p>
          {snapshot.missing_uids.length > 0 ? (
            <div className="max-h-64 overflow-auto border border-border p-3">
              <ul className="grid gap-1 text-sm">
                {snapshot.missing_uids.map(uid => (
                  <li key={uid}>{uid}</li>
                ))}
              </ul>
            </div>
          ) : null}
        </>
      ) : (
        <p className="text-sm text-muted-foreground">{t('console.directory_access.no_snapshot')}</p>
      )}
      <LabeledField label={t('console.human_access.reason')}>
        <Textarea
          rows={2}
          value={model.reason.value}
          onChange={e => {
            model.reason.value = e.target.value
          }}
        />
      </LabeledField>
      {snapshot?.status === 'review_required' && snapshot.snapshot_fingerprint ? (
        <>
          <label className="flex items-start gap-3 text-sm">
            <Checkbox
              checked={confirmed}
              onCheckedChange={checked => {
                model.approvedFingerprint.value =
                  checked === true ? (snapshot.snapshot_fingerprint ?? undefined) : undefined
              }}
            />
            <span>{t('console.directory_access.confirm')}</span>
          </label>
          <Button
            type="button"
            className="justify-self-start"
            disabled={pending || !model.hasReason.value || !confirmed}
            onClick={() =>
              approve.mutate({
                path: { provider_id: providerID },
                body: {
                  reason: model.reason.value.trim(),
                  snapshot_fingerprint: model.approvedFingerprint.value!,
                  confirm_removals: true
                }
              })
            }>
            {t('console.directory_access.approve')}
          </Button>
        </>
      ) : null}
      {directory.data?.events.map(event => (
        <div key={event.id} className="grid gap-3 border border-border p-4">
          <div className="flex flex-wrap items-center justify-between gap-2 text-sm">
            <span className="font-medium">{event.event_type}</span>
            <Badge variant="outline">{event.status}</Badge>
          </div>
          <p className="text-sm">{event.reason ?? event.last_error}</p>
          <code className="text-xs break-all text-muted-foreground">{event.external_ids.join(', ')}</code>
          {event.status === 'pending' || event.status === 'review_required' ? (
            <div className="flex gap-2">
              <Button
                type="button"
                size="sm"
                variant="outline"
                disabled={pending || !model.hasReason.value}
                onClick={() =>
                  review.mutate({
                    path: { provider_id: providerID, event_id: event.id },
                    body: { action: 'retry', reason: model.reason.value.trim() }
                  })
                }>
                {t('common.retry')}
              </Button>
              <Button
                type="button"
                size="sm"
                variant="outline"
                disabled={pending || !model.hasReason.value}
                onClick={() =>
                  review.mutate({
                    path: { provider_id: providerID, event_id: event.id },
                    body: { action: 'dismiss', reason: model.reason.value.trim() }
                  })
                }>
                {t('console.directory_access.dismiss')}
              </Button>
            </div>
          ) : null}
          {event.review_reason ? (
            <p className="text-xs text-muted-foreground">
              {event.reviewed_by} · {event.review_reason}
            </p>
          ) : null}
        </div>
      ))}
    </section>
  )
}
