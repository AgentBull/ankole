import { useMutation, useQuery } from '../tenant-context'
import { ActorLabel } from '../actor-label'
import { Badge, Button, Checkbox, Textarea, toast } from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'

import { useTranslation } from 'react-i18next'
import {
  getIdentityDirectoryOptions,
  approveIdentityDirectoryMutation,
  reviewIdentityDirectoryEventMutation,
  listPrincipalsOptions
} from '../api/v2/generated/@tanstack/react-query.gen'
import { AccessReviewModel } from '../state/access-review-model'
import { ErrorBlock } from '../../common/error-block'
import { requestErrorMessage } from '../../common/request-errors'
import { LabeledField } from '../console-form'
import { formatConsoleDate } from '../console-primitives'
import { fromDocument } from '../api/json-api'
import { principalLabel } from '../state/principal-label'
import type { GetIdentityDirectoryResponse } from '../api/v2/generated/types.gen'

function humanizeToken(value: string): string {
  return value
    .replace(/[._-]+/g, ' ')
    .trim()
    .replace(/^\w/, char => char.toUpperCase())
}

function snapshotStatusVariant(status: string) {
  if (status === 'healthy') return 'success' as const
  if (status === 'review_required') return 'warning' as const
  if (status === 'failed') return 'destructive' as const
  return 'outline' as const
}

export function DirectoryAccessSection({ providerID }: { providerID: string }) {
  useSignals()
  const { t } = useTranslation()
  const model = useModel(AccessReviewModel)
  const directory = useQuery({
    ...getIdentityDirectoryOptions({ path: { provider_id: providerID } }),
    refetchInterval: 15000
  })
  const principals = useQuery({
    ...listPrincipalsOptions({ query: { include_disabled: true } }),
    select: data => fromDocument(data)
  })
  const onSuccess = () => {
    model.reason.value = ''
    model.approvedFingerprint.value = undefined
    toast.success(t('console.human_access.saved'))
  }
  const onError = (error: unknown) => toast.error(requestErrorMessage(error))
  const approve = useMutation({ ...approveIdentityDirectoryMutation(), onSuccess, onError })
  const snapshot = directory.data?.snapshot
  const pending = approve.isPending
  const confirmed = Boolean(
    snapshot?.snapshot_fingerprint && model.approvedFingerprint.value === snapshot.snapshot_fingerprint
  )
  return (
    <section className="grid gap-4 border-t border-border pt-6">
      <h3 className="title-section">{t('console.directory_access.title')}</h3>
      <p className="text-sm text-muted-foreground">{t('console.directory_access.hint')}</p>
      <ErrorBlock error={directory.error} />
      {directory.isLoading ? <p role="status">{t('common.loading')}</p> : null}
      {snapshot ? (
        <>
          <div className="flex flex-wrap items-center gap-3 text-sm">
            <Badge title={snapshot.status} variant={snapshotStatusVariant(snapshot.status)}>
              {t(`console.directory_access.status_${snapshot.status}`, {
                defaultValue: humanizeToken(snapshot.status)
              })}
            </Badge>
            <span>
              {snapshot.last_success_at
                ? formatConsoleDate(snapshot.last_success_at)
                : t('console.directory_access.no_snapshot')}
            </span>
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
                {snapshot.missing_uids.map(uid => {
                  const person = principals.data?.find(person => person.id === uid)
                  return (
                    <li key={uid} title={uid}>
                      {person ? principalLabel(person) : uid}
                    </li>
                  )
                })}
              </ul>
            </div>
          ) : null}
        </>
      ) : (
        <p className="text-sm text-muted-foreground">{t('console.directory_access.no_snapshot')}</p>
      )}
      {snapshot?.status === 'review_required' && snapshot.snapshot_fingerprint ? (
        <>
          <LabeledField label={t('console.human_access.reason')} required>
            <Textarea
              rows={2}
              value={model.reason.value}
              onChange={e => {
                model.reason.value = e.target.value
              }}
            />
          </LabeledField>

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
                  data: {
                    reason: model.reason.value.trim(),
                    snapshot_fingerprint: model.approvedFingerprint.value!,
                    confirm_removals: true
                  }
                }
              })
            }>
            {t('console.directory_access.approve')}
          </Button>
        </>
      ) : null}
      {directory.data?.events.map(event => (
        <DirectoryEventReview key={event.id} providerID={providerID} event={event} />
      ))}
    </section>
  )
}

function DirectoryEventReview({
  providerID,
  event
}: {
  providerID: string
  event: GetIdentityDirectoryResponse['events'][number]
}) {
  useSignals()
  const { t } = useTranslation()
  const model = useModel(AccessReviewModel)
  const review = useMutation({
    ...reviewIdentityDirectoryEventMutation(),
    onSuccess: () => {
      model.reason.value = ''
      toast.success(t('console.human_access.saved'))
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const pending = review.isPending
  const eventTypeKey = event.event_type.replace(/[^a-zA-Z0-9]+/g, '_')
  return (
    <div className="grid gap-3 border border-border p-4">
      <div className="flex flex-wrap items-center justify-between gap-2 text-sm">
        <span className="font-medium" title={event.event_type}>
          {t(`console.directory_access.event_type_${eventTypeKey}`, {
            defaultValue: humanizeToken(event.event_type)
          })}
        </span>
        <Badge title={event.status} variant={snapshotStatusVariant(event.status)}>
          {t(`console.directory_access.event_status_${event.status}`, {
            defaultValue: humanizeToken(event.status)
          })}
        </Badge>
      </div>
      <p className="text-sm">{event.reason ?? event.last_error}</p>
      <code className="text-xs break-all text-muted-foreground">{event.external_ids.join(', ')}</code>
      {event.status === 'pending' || event.status === 'review_required' ? (
        <div className="grid gap-3">
          <LabeledField label={t('console.human_access.reason')} required>
            <Textarea
              rows={2}
              value={model.reason.value}
              onChange={e => {
                model.reason.value = e.target.value
              }}
            />
          </LabeledField>
          <div className="flex gap-2">
            <Button
              type="button"
              size="sm"
              variant="outline"
              disabled={pending || !model.hasReason.value}
              onClick={() =>
                review.mutate({
                  path: { provider_id: providerID, event_id: event.id },
                  body: { data: { action: 'retry', reason: model.reason.value.trim() } }
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
                  body: { data: { action: 'dismiss', reason: model.reason.value.trim() } }
                })
              }>
              {t('console.directory_access.dismiss')}
            </Button>
          </div>
        </div>
      ) : null}
      {event.review_reason ? (
        <p className="text-xs text-muted-foreground">
          <ActorLabel actor={event.reviewed_by} /> · {event.review_reason}
        </p>
      ) : null}
    </div>
  )
}
