import { humanizeTechnicalLabel } from '../../common/humanize-technical-label'
import { useQuery } from '../tenant-context'
import { ActorLabel } from '../actor-label'
import { Badge, Skeleton } from '@ankole/uikit'

import { useTranslation } from 'react-i18next'
import { getIdentityDirectoryOptions, listPrincipalsOptions } from '../api/v2/generated/@tanstack/react-query.gen'
import { ErrorBlock } from '../../common/error-block'
import { formatConsoleDate } from '../console-primitives'
import { LIST_REFRESH_MS } from '../refresh-intervals'
import { fromDocument } from '../api/json-api'
import { principalLabel } from '../state/principal-label'
import type { GetIdentityDirectoryResponse } from '../api/v2/generated/types.gen'

function snapshotStatusVariant(status: string) {
  if (status === 'healthy') return 'success' as const
  if (status === 'review_required') return 'warning' as const
  if (status === 'failed') return 'destructive' as const
  return 'outline' as const
}

export function DirectoryAccessSection({ providerID }: { providerID: string }) {
  const { t } = useTranslation()
  const directory = useQuery({
    ...getIdentityDirectoryOptions({ path: { provider_id: providerID } }),
    refetchInterval: LIST_REFRESH_MS
  })
  const principals = useQuery({
    ...listPrincipalsOptions({ query: { include_disabled: true } }),
    select: data => fromDocument(data)
  })
  const snapshot = directory.data?.snapshot
  return (
    <section className="grid gap-4 border-t border-border-subtle pt-6">
      <h3 className="title-section">{t('console.directory_access.title')}</h3>
      <p className="text-sm text-fg-secondary">{t('console.directory_access.hint')}</p>
      <ErrorBlock error={directory.error} />
      {directory.isLoading ? <p role="status">{t('common.loading')}</p> : null}
      {snapshot ? (
        <>
          <div className="flex flex-wrap items-center gap-3 text-sm">
            <Badge title={snapshot.status} variant={snapshotStatusVariant(snapshot.status)}>
              {t(`console.directory_access.status_${snapshot.status}`, {
                defaultValue: humanizeTechnicalLabel(snapshot.status.replaceAll('.', '_'))
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
            <div className="max-h-64 overflow-auto border border-border-subtle p-3">
              <ul className="grid gap-1 text-sm">
                {snapshot.missing_uids.map(uid => {
                  const person = principals.data?.find(person => person.id === uid)
                  return (
                    <li key={uid} title={person || !principals.isPending ? uid : undefined}>
                      {person ? principalLabel(person) : principals.isPending ? <Skeleton className="h-4 w-36" /> : uid}
                    </li>
                  )
                })}
              </ul>
            </div>
          ) : null}
        </>
      ) : (
        <p className="text-sm text-fg-secondary">{t('console.directory_access.no_snapshot')}</p>
      )}
      {directory.data?.events.map(event => (
        <DirectoryEventReview key={event.id} event={event} />
      ))}
    </section>
  )
}

function DirectoryEventReview({ event }: { event: GetIdentityDirectoryResponse['events'][number] }) {
  const { t } = useTranslation()
  const eventTypeKey = event.event_type.replace(/[^a-zA-Z0-9]+/g, '_')
  return (
    <div className="grid gap-3 border border-border-subtle p-4">
      <div className="flex flex-wrap items-center justify-between gap-2 text-sm">
        <span className="font-medium" title={event.event_type}>
          {t(`console.directory_access.event_type_${eventTypeKey}`, {
            defaultValue: humanizeTechnicalLabel(event.event_type.replaceAll('.', '_'))
          })}
        </span>
        <Badge title={event.status} variant={snapshotStatusVariant(event.status)}>
          {t(`console.directory_access.event_status_${event.status}`, {
            defaultValue: humanizeTechnicalLabel(event.status.replaceAll('.', '_'))
          })}
        </Badge>
      </div>
      <p className="text-sm">{event.reason ?? event.last_error}</p>
      <code className="text-xs break-all text-fg-secondary">{event.external_ids.join(', ')}</code>
      {event.review_reason ? (
        <p className="text-xs text-fg-secondary">
          <ActorLabel actor={event.reviewed_by} /> · {event.review_reason}
        </p>
      ) : null}
    </div>
  )
}
