import {
  Badge,
  Button,
  Dialog,
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  Input,
  Sheet,
  SheetContent,
  SheetDescription,
  SheetFooter,
  SheetHeader,
  SheetTitle,
  Skeleton,
  toast
} from '@ankole/uikit'
import { RiCloseCircleLine, RiTimeLine } from '@remixicon/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useSearchParams } from 'react-router'
import { requestErrorMessage } from '../../common/request-errors'
import {
  ankoleWebSubagentDelegationControllerCancelMutation,
  ankoleWebSubagentDelegationControllerIndexOptions,
  ankoleWebSubagentDelegationControllerShowOptions
} from '../api/generated/@tanstack/react-query.gen'
import type { SubagentDelegationItem } from '../api/generated/types.gen'
import { ErrorBlock } from '../console-primitives'

type Column = {
  key: 'todo' | 'active' | 'finished'
  statuses: SubagentDelegationItem['status'][]
}

type DelegationEvent = NonNullable<SubagentDelegationItem['events']>[number]

const columns: Column[] = [
  { key: 'todo', statuses: ['queued'] },
  { key: 'active', statuses: ['running', 'waiting_on_user'] },
  { key: 'finished', statuses: ['succeeded', 'failed', 'stopped'] }
]

export function DelegationsPage() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const [searchParams, setSearchParams] = useSearchParams()
  const agentFilter = searchParams.get('agent') ?? ''
  const selectedID = searchParams.get('delegation') ?? undefined
  const [cancelTargetID, setCancelTargetID] = useState<string>()
  const list = useQuery({
    ...ankoleWebSubagentDelegationControllerIndexOptions({
      query: { agent: agentFilter.trim() || undefined, limit: 100 }
    }),
    refetchInterval: 5_000
  })
  const detail = useQuery({
    ...ankoleWebSubagentDelegationControllerShowOptions({
      path: { delegation_id: selectedID ?? 'not-selected' }
    }),
    enabled: Boolean(selectedID),
    refetchInterval: selectedID ? 5_000 : false
  })
  const cancel = useMutation({
    ...ankoleWebSubagentDelegationControllerCancelMutation(),
    onSuccess: () => {
      toast.success(t('console.delegations.cancelled'))
      setCancelTargetID(undefined)
      void queryClient.invalidateQueries()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const delegations = list.data?.delegations ?? []
  const selected = detail.data?.delegation
  const cancelTarget =
    delegations.find(delegation => delegation.id === cancelTargetID) ??
    (selected?.id === cancelTargetID ? selected : undefined)

  const setAgentFilter = (value: string) => {
    const next = new URLSearchParams(searchParams)
    if (value) next.set('agent', value)
    else next.delete('agent')
    setSearchParams(next, { replace: true })
  }

  const openDelegation = (id: string) => {
    const next = new URLSearchParams(searchParams)
    next.set('delegation', id)
    setSearchParams(next)
  }

  const closeDelegation = () => {
    const next = new URLSearchParams(searchParams)
    next.delete('delegation')
    setSearchParams(next, { replace: true })
  }

  const grouped = useMemo(
    () =>
      Object.fromEntries(
        columns.map(column => [
          column.key,
          delegations.filter(delegation => column.statuses.includes(delegation.status))
        ])
      ) as Record<Column['key'], SubagentDelegationItem[]>,
    [delegations]
  )

  return (
    <div className="grid gap-6">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div className="grid gap-1">
          <h2 className="text-2xl font-semibold tracking-normal">{t('console.delegations.title')}</h2>
          <p className="max-w-3xl text-sm leading-6 text-muted-foreground">{t('console.delegations.description')}</p>
        </div>
        <Input
          className="w-full sm:w-64"
          aria-label={t('console.delegations.agent_filter')}
          placeholder={t('console.delegations.agent_filter')}
          value={agentFilter}
          onChange={event => setAgentFilter(event.target.value)}
        />
      </div>

      <ErrorBlock error={list.error} />

      <div className="grid min-w-0 gap-4 xl:grid-cols-3">
        {columns.map(column => (
          <section key={column.key} className="min-h-72 border border-border bg-muted/25">
            <header className="flex items-center justify-between border-b border-border bg-card px-4 py-3">
              <h3 className="font-medium">{t(`console.delegations.column_${column.key}`)}</h3>
              <Badge variant="secondary">{grouped[column.key].length}</Badge>
            </header>
            <div className="grid gap-3 p-3">
              {list.isLoading ? (
                <>
                  <Skeleton className="h-36 w-full" />
                  <Skeleton className="h-28 w-full" />
                </>
              ) : grouped[column.key].length === 0 ? (
                <p className="px-2 py-10 text-center text-sm text-muted-foreground">
                  {t('console.delegations.empty_column')}
                </p>
              ) : (
                grouped[column.key].map(task => (
                  <DelegationCard
                    key={task.id}
                    task={task}
                    cancelling={cancel.isPending}
                    onCancel={() => setCancelTargetID(task.id)}
                    onOpen={() => openDelegation(task.id)}
                  />
                ))
              )}
            </div>
          </section>
        ))}
      </div>

      <Sheet open={Boolean(selectedID)} onOpenChange={open => !open && closeDelegation()}>
        <SheetContent className="w-full sm:max-w-2xl">
          <SheetHeader>
            <SheetTitle>{selected?.title ?? t('console.delegations.detail_title')}</SheetTitle>
            <SheetDescription>{selected ? `${selected.agent_uid} · ${selected.id}` : ''}</SheetDescription>
          </SheetHeader>

          <div className="grid flex-1 gap-6 overflow-y-auto px-8 pb-8">
            <ErrorBlock error={detail.error} />
            {detail.isLoading || !selected ? (
              <Skeleton className="h-64 w-full" />
            ) : (
              <>
                <dl className="grid grid-cols-2 gap-x-6 gap-y-3 border border-border bg-card p-4 text-sm">
                  <DetailField label={t('console.delegations.status')} value={selected.status} />
                  <DetailField label={t('console.delegations.runtime')} value={selected.runtime} />
                  <DetailField label={t('console.delegations.codex_account')} value={selected.codex_account_id} />
                  <DetailField label={t('console.delegations.attempts')} value={String(selected.attempts)} />
                  <DetailField
                    label={t('console.delegations.duration')}
                    value={formatDuration(selected.duration_seconds)}
                  />
                  <DetailField label={t('console.delegations.workdir')} value={selected.workdir ?? '—'} wide />
                  <DetailField label={t('console.delegations.task')} value={selected.task ?? '—'} wide />
                  <DetailField label={t('console.delegations.background')} value={selected.background ?? '—'} wide />
                  <DetailField label={t('console.delegations.notes')} value={selected.notes ?? '—'} wide />
                  <DetailField
                    label={t('console.delegations.result')}
                    value={summary(selected.status === 'failed' ? selected.error : selected.result)}
                    wide
                  />
                </dl>

                <section className="grid gap-3">
                  <h3 className="font-medium">{t('console.delegations.timeline')}</h3>
                  {selected.events?.length ? (
                    <div className="grid gap-5">
                      {groupEventsByAttempt(selected.events).map(group => (
                        <section key={group.attempt} className="grid gap-2">
                          <h4 className="text-xs font-medium text-muted-foreground">
                            {t('console.delegations.attempt_label', { count: group.attempt })}
                          </h4>
                          <ol className="grid gap-3 border-l border-border pl-5">
                            {group.events.map(event => (
                              <li key={event.id} className="relative grid gap-1 border border-border bg-card p-3">
                                <span className="absolute top-4 -left-[1.43rem] size-2.5 rounded-full bg-primary" />
                                <div className="flex flex-wrap items-center justify-between gap-2">
                                  <span className="font-mono text-xs">
                                    #{event.seq} · {event.event_type}
                                  </span>
                                  <span className="text-xs text-muted-foreground">{formatDate(event.occurred_at)}</span>
                                </div>
                                <span className="text-xs text-muted-foreground">{event.direction}</span>
                                <pre className="mt-1 max-h-40 overflow-auto whitespace-pre-wrap break-all bg-muted p-2 text-xs">
                                  {truncate(JSON.stringify(event.payload, null, 2), 2_000)}
                                </pre>
                              </li>
                            ))}
                          </ol>
                        </section>
                      ))}
                    </div>
                  ) : (
                    <p className="text-sm text-muted-foreground">{t('console.delegations.no_events')}</p>
                  )}
                </section>
              </>
            )}
          </div>

          {selected && cancellable(selected.status) ? (
            <SheetFooter>
              <Button variant="destructive" disabled={cancel.isPending} onClick={() => setCancelTargetID(selected.id)}>
                <RiCloseCircleLine />
                {t('console.delegations.cancel')}
              </Button>
            </SheetFooter>
          ) : null}
        </SheetContent>
      </Sheet>

      <Dialog open={Boolean(cancelTarget)} onOpenChange={open => !open && setCancelTargetID(undefined)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{t('console.delegations.cancel_title')}</DialogTitle>
            <DialogDescription>
              {t('console.delegations.cancel_confirm', {
                title: cancelTarget?.title ?? cancelTarget?.id ?? ''
              })}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <DialogClose render={<Button variant="outline" />}>{t('common.cancel')}</DialogClose>
            <Button
              variant="destructive"
              disabled={!cancelTarget || cancel.isPending}
              onClick={() => cancelTarget && cancel.mutate({ path: { delegation_id: cancelTarget.id } })}>
              {t('console.delegations.cancel')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  )
}

function DelegationCard({
  task,
  cancelling,
  onCancel,
  onOpen
}: {
  task: SubagentDelegationItem
  cancelling: boolean
  onCancel: () => void
  onOpen: () => void
}) {
  const { t } = useTranslation()

  return (
    <article className="grid gap-3 border border-border bg-card p-4 shadow-xs">
      <button type="button" className="grid gap-3 text-left" onClick={onOpen}>
        <div className="flex items-start justify-between gap-3">
          <h4 className="line-clamp-2 font-medium leading-5">{task.title ?? task.id}</h4>
          <StatusBadge status={task.status} />
        </div>
        <div className="grid gap-1 text-xs text-muted-foreground">
          <span className="truncate font-mono">{task.agent_uid}</span>
          <span className="flex items-center gap-1.5">
            <RiTimeLine className="size-3.5" />
            {formatDuration(task.duration_seconds)} · {t('console.delegations.attempt_count', { count: task.attempts })}
          </span>
          <span>{task.runtime}</span>
        </div>
      </button>
      {cancellable(task.status) ? (
        <Button size="xs" variant="outline" disabled={cancelling} onClick={onCancel}>
          {t('console.delegations.cancel')}
        </Button>
      ) : null}
    </article>
  )
}

function StatusBadge({ status }: { status: SubagentDelegationItem['status'] }) {
  const variant =
    status === 'failed' || status === 'stopped' ? 'destructive' : status === 'succeeded' ? 'default' : 'secondary'
  return <Badge variant={variant}>{status}</Badge>
}

function DetailField({ label, value, wide = false }: { label: string; value: string; wide?: boolean }) {
  return (
    <div className={wide ? 'col-span-2 grid gap-1' : 'grid gap-1'}>
      <dt className="text-xs text-muted-foreground">{label}</dt>
      <dd className="whitespace-pre-wrap break-words">{value}</dd>
    </div>
  )
}

function groupEventsByAttempt(events: DelegationEvent[]) {
  const groups = new Map<number, DelegationEvent[]>()
  for (const event of events) {
    const attempt = typeof event.payload.attempt === 'number' ? event.payload.attempt : 1
    groups.set(attempt, [...(groups.get(attempt) ?? []), event])
  }
  return [...groups.entries()]
    .sort(([left], [right]) => left - right)
    .map(([attempt, attemptEvents]) => ({ attempt, events: attemptEvents }))
}

function cancellable(status: SubagentDelegationItem['status']): boolean {
  return status === 'queued' || status === 'running' || status === 'waiting_on_user'
}

function formatDuration(seconds: number): string {
  if (seconds < 60) return `${seconds}s`
  if (seconds < 3_600) return `${Math.floor(seconds / 60)}m`
  if (seconds < 86_400) return `${Math.floor(seconds / 3_600)}h ${Math.floor((seconds % 3_600) / 60)}m`
  return `${Math.floor(seconds / 86_400)}d ${Math.floor((seconds % 86_400) / 3_600)}h`
}

function formatDate(value: string): string {
  return new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(value))
}

function summary(value: Record<string, unknown>): string {
  for (const key of ['summary', 'output_text', 'message', 'reason', 'code']) {
    if (typeof value[key] === 'string' && value[key]) return String(value[key])
  }
  return Object.keys(value).length ? truncate(JSON.stringify(value, null, 2), 4_000) : '—'
}

function truncate(value: string, limit: number): string {
  return value.length <= limit ? value : `${value.slice(0, limit)}…`
}
