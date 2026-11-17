import { Badge, Button, Checkbox, Label, Skeleton, Textarea, toast } from '@ankole/uikit'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { formatDateTime } from '../common/date-time'
import { humanizeTechnicalLabel } from '../common/humanize-technical-label'
import * as api from './api/generated/sdk.gen'
import type { PodAdminIdentityDirectoryResponse, PodAdminMembersResponse } from './api/generated/types.gen'
import { ContentError } from './content-primitives'

type Member = PodAdminMembersResponse['members'][number]
type DirectoryEvent = PodAdminIdentityDirectoryResponse['events'][number]

function snapshotStatusVariant(status: string) {
  if (status === 'healthy') return 'success' as const
  if (status === 'review_required') return 'warning' as const
  if (status === 'failed') return 'destructive' as const
  return 'outline' as const
}

export function PodProviderDirectoryReview({
  providerID,
  members,
  membersLoading = false
}: {
  providerID: string
  members?: Member[]
  membersLoading?: boolean
}) {
  const { t } = useTranslation()
  const client = useQueryClient()
  const queryKey = ['pod-admin-directory', providerID] as const
  const [reason, setReason] = useState('')
  const [confirmedFingerprint, setConfirmedFingerprint] = useState<string>()

  const directory = useQuery({
    queryKey,
    queryFn: () => api.podAdminIdentityDirectory({ path: { provider_id: providerID } }),
    refetchInterval: 5_000
  })
  const approve = useMutation({
    mutationFn: (fingerprint: string) =>
      api.approvePodIdentityDirectory({
        path: { provider_id: providerID },
        body: {
          data: {
            reason: reason.trim(),
            snapshot_fingerprint: fingerprint,
            confirm_removals: true
          }
        }
      }),
    onSuccess: () => {
      setReason('')
      setConfirmedFingerprint(undefined)
      toast.success(t('console.human_access.saved'))
      void client.invalidateQueries({ queryKey })
      void client.invalidateQueries({ queryKey: ['pod-admin-members'] })
    }
  })

  const snapshot = directory.data?.snapshot
  const events = directory.data?.events ?? []
  const needsAttention =
    snapshot?.status === 'review_required' ||
    snapshot?.status === 'failed' ||
    events.some(event => event.status === 'pending' || event.status === 'review_required')

  if (!snapshot && events.length === 0 && !directory.error) return null

  const confirmed = Boolean(snapshot?.snapshot_fingerprint && confirmedFingerprint === snapshot.snapshot_fingerprint)

  return (
    <details open={needsAttention} className="w-full border-t border-border-subtle pt-3">
      <summary className="flex cursor-pointer flex-wrap items-center gap-2 text-sm font-medium">
        <span>{t('console.directory_access.title')}</span>
        {snapshot ? (
          <Badge variant={snapshotStatusVariant(snapshot.status)}>
            {t(`console.directory_access.status_${snapshot.status}`, {
              defaultValue: humanizeTechnicalLabel(snapshot.status.replaceAll('.', '_'))
            })}
          </Badge>
        ) : null}
      </summary>
      <div className="mt-3 grid gap-3">
        <p className="text-xs text-fg-secondary">{t('console.directory_access.hint')}</p>
        <ContentError error={directory.error ?? approve.error} />
        {snapshot ? (
          <>
            <div className="flex flex-wrap items-center gap-3 text-xs text-fg-secondary">
              <span>
                {snapshot.last_success_at
                  ? formatDateTime(snapshot.last_success_at, undefined, 'medium')
                  : t('console.directory_access.no_snapshot')}
              </span>
              <span>
                {t('console.directory_access.counts', {
                  members: snapshot.member_uids.length,
                  missing: snapshot.missing_uids.length
                })}
              </span>
            </div>
            {snapshot.last_error ? <p className="text-sm text-destructive">{snapshot.last_error}</p> : null}
            {snapshot.missing_uids.length > 0 ? (
              <div className="max-h-48 overflow-auto rounded-md border border-border-subtle p-2.5">
                <ul className="grid gap-1 text-xs">
                  {snapshot.missing_uids.map(uid => {
                    const person = members?.find(member => member.uid === uid)
                    return (
                      <li key={uid} title={person || !membersLoading ? uid : undefined}>
                        {person ? (
                          [person.displayName, person.email].filter(Boolean).join(' · ')
                        ) : membersLoading ? (
                          <Skeleton className="h-3.5 w-36" />
                        ) : (
                          uid
                        )}
                      </li>
                    )
                  })}
                </ul>
              </div>
            ) : null}
            {snapshot.status === 'review_required' && snapshot.snapshot_fingerprint ? (
              <div className="grid gap-3 rounded-lg border border-border-subtle bg-layer-03/20 p-3">
                <div className="grid gap-1.5">
                  <Label htmlFor={`dir-reason-${providerID}`}>{t('console.human_access.reason')}</Label>
                  <Textarea
                    id={`dir-reason-${providerID}`}
                    rows={2}
                    value={reason}
                    onChange={event => setReason(event.target.value)}
                  />
                </div>
                <label className="flex items-start gap-2.5 text-sm">
                  <Checkbox
                    checked={confirmed}
                    onCheckedChange={checked =>
                      setConfirmedFingerprint(
                        checked === true ? (snapshot.snapshot_fingerprint ?? undefined) : undefined
                      )
                    }
                  />
                  <span>{t('console.directory_access.confirm')}</span>
                </label>
                <Button
                  type="button"
                  size="sm"
                  className="justify-self-start"
                  disabled={approve.isPending || !reason.trim() || !confirmed}
                  onClick={() => approve.mutate(snapshot.snapshot_fingerprint!)}>
                  {t('console.directory_access.approve')}
                </Button>
              </div>
            ) : null}
          </>
        ) : null}
        {events.map(event => (
          <PodDirectoryEventItem
            key={event.id}
            providerID={providerID}
            event={event}
            members={members}
            membersLoading={membersLoading}
            onUpdated={() => void client.invalidateQueries({ queryKey })}
          />
        ))}
      </div>
    </details>
  )
}

function PodDirectoryEventItem({
  providerID,
  event,
  members,
  membersLoading = false,
  onUpdated
}: {
  providerID: string
  event: DirectoryEvent
  members?: Member[]
  membersLoading?: boolean
  onUpdated: () => void
}) {
  const { t } = useTranslation()
  const client = useQueryClient()
  const [reason, setReason] = useState('')
  const review = useMutation({
    mutationFn: (action: 'retry' | 'dismiss') =>
      api.reviewPodIdentityDirectoryEvent({
        path: { provider_id: providerID, event_id: event.id },
        body: { data: { action, reason: reason.trim() } }
      }),
    onSuccess: () => {
      setReason('')
      toast.success(t('console.human_access.saved'))
      onUpdated()
      void client.invalidateQueries({ queryKey: ['pod-admin-members'] })
    }
  })
  const eventTypeKey = event.event_type.replace(/[^a-zA-Z0-9]+/g, '_')
  const actionable = event.status === 'pending' || event.status === 'review_required'
  const reviewer = event.reviewed_by ? members?.find(member => member.uid === event.reviewed_by?.uid) : undefined

  return (
    <div className="grid gap-2 rounded-lg border border-border-subtle p-3 text-sm">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <span className="font-medium">
          {t(`console.directory_access.event_type_${eventTypeKey}`, {
            defaultValue: humanizeTechnicalLabel(event.event_type.replaceAll('.', '_'))
          })}
        </span>
        <Badge variant={snapshotStatusVariant(event.status)}>
          {t(`console.directory_access.event_status_${event.status}`, {
            defaultValue: humanizeTechnicalLabel(event.status.replaceAll('.', '_'))
          })}
        </Badge>
      </div>
      {event.reason || event.last_error ? <p className="text-xs">{event.reason ?? event.last_error}</p> : null}
      <code className="text-xs break-all text-fg-secondary">{event.external_ids.join(', ')}</code>
      {event.review_reason ? (
        <p className="flex flex-wrap items-center gap-1 text-xs text-fg-secondary">
          {event.reviewed_by ? (
            <>
              {reviewer ? (
                <span>{reviewer.displayName}</span>
              ) : membersLoading ? (
                <Skeleton className="inline-block h-3.5 w-20" />
              ) : (
                <span>{event.reviewed_by.uid}</span>
              )}
              <span aria-hidden>·</span>
            </>
          ) : null}
          <span>{event.review_reason}</span>
        </p>
      ) : null}
      <ContentError error={review.error} />
      {actionable ? (
        <div className="grid gap-2">
          <Label htmlFor={`dir-ev-${event.id}`}>{t('console.human_access.reason')}</Label>
          <Textarea id={`dir-ev-${event.id}`} rows={2} value={reason} onChange={e => setReason(e.target.value)} />
          <div className="flex flex-wrap gap-2">
            <Button
              type="button"
              size="sm"
              variant="outline"
              disabled={review.isPending || !reason.trim()}
              onClick={() => review.mutate('retry')}>
              {t('common.retry')}
            </Button>
            <Button
              type="button"
              size="sm"
              variant="outline"
              disabled={review.isPending || !reason.trim()}
              onClick={() => review.mutate('dismiss')}>
              {t('console.directory_access.dismiss')}
            </Button>
          </div>
        </div>
      ) : null}
    </div>
  )
}

export function PodMemberAccessCleanup({ uid }: { uid: string }) {
  const { t } = useTranslation()
  const [open, setOpen] = useState(false)
  const client = useQueryClient()
  const queryKey = ['pod-admin-member-access', uid] as const

  const access = useQuery({
    queryKey,
    queryFn: () => api.podAdminMemberAccess({ path: { uid } }),
    enabled: open
  })
  const retry = useMutation({
    mutationFn: () => api.retryPodMemberWorkCleanup({ path: { uid } }),
    onSuccess: () => {
      toast.success(t('console.human_access.saved'))
      void client.invalidateQueries({ queryKey })
    }
  })

  const state = access.data
  const activeRestrictions = state?.restrictions.filter(item => !item.cleared_at) ?? []

  return (
    <details
      open={open}
      onToggle={event => setOpen((event.currentTarget as HTMLDetailsElement).open)}
      className="border-t border-border-subtle pt-3">
      <summary className="cursor-pointer text-xs font-medium text-fg-secondary">
        {t('console.human_access.work')}
      </summary>
      <div className="mt-3 grid gap-3 text-sm">
        <p className="text-xs text-fg-secondary">{t('console.human_access.work_hint')}</p>
        <ContentError error={access.error ?? retry.error} />
        {access.isLoading ? <p className="text-xs text-fg-secondary">{t('common.loading')}</p> : null}
        {state ? (
          <>
            {activeRestrictions.map(item => (
              <div
                key={item.id}
                className="grid gap-1 rounded-md border border-border-subtle bg-layer-03/20 p-2.5 text-xs">
                <span className="font-medium">
                  {humanizeTechnicalLabel(item.disposition)} · {humanizeTechnicalLabel(item.source)}
                </span>
                <span>{item.reason}</span>
              </div>
            ))}
            <div className="grid gap-1 text-xs">
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
              className="justify-self-start"
              disabled={retry.isPending}
              onClick={() => retry.mutate()}>
              {t('console.human_access.retry_cleanup')}
            </Button>
            {state.work.length > 0 ? (
              <div className="grid gap-1.5">
                {state.work.map(work => (
                  <div
                    key={`${work.kind}:${work.id}`}
                    className="grid gap-0.5 border-b border-border-subtle py-1.5 text-xs">
                    <span>
                      {humanizeTechnicalLabel(work.kind)} · {humanizeTechnicalLabel(work.status)}
                    </span>
                    <code className="break-all text-fg-secondary">{work.id}</code>
                  </div>
                ))}
              </div>
            ) : null}
          </>
        ) : null}
      </div>
    </details>
  )
}
