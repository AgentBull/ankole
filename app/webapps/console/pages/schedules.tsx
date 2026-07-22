import {
  Button,
  buttonVariants,
  Input,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  Switch,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
  Tabs,
  TabsContent,
  TabsList,
  TabsTrigger,
  toast
} from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useNavigate, useSearchParams } from 'react-router'
import { requestErrorMessage } from '../../common/request-errors'
import {
  ankoleWebAgentControllerIndexOptions,
  ankoleWebAgentSessionControllerIndexOptions,
  ankoleWebScheduleControllerCancelCheckbackMutation,
  ankoleWebScheduleControllerCreateCronMutation,
  ankoleWebScheduleControllerCronRunsOptions,
  ankoleWebScheduleControllerIndexCheckbacksOptions,
  ankoleWebScheduleControllerIndexCronOptions,
  ankoleWebScheduleControllerPauseCronMutation,
  ankoleWebScheduleControllerRemoveCronMutation,
  ankoleWebScheduleControllerResumeCronMutation,
  ankoleWebScheduleControllerRunCronMutation,
  ankoleWebScheduleControllerShowCronOptions,
  ankoleWebScheduleControllerUpdateCronMutation,
  ankoleWebSignalBindingControllerIndexOptions
} from '../api/generated/@tanstack/react-query.gen'
import { formatConsoleDate } from '../console-primitives'
import {
  ConfirmDeleteButton,
  LabeledField,
  PageHeader,
  ReadOnlyValue,
  RowActions,
  StatusIndicator
} from '../console-shell'
import {
  ScheduleEditorModel,
  type CronStatus,
  type ScheduleEditorDraft,
  type ScheduleKind
} from '../state/schedule-editor-model'
import { matchesResourceSearch } from '../state/resource-search'

// Cron projections arrive as JSONValue (unknown); this is the runtime shape the
// control plane's Schedule.Projections emits. Keep it loose — the source of
// truth is the Elixir projection, not this type.
type CronScheduleRow = {
  id: string
  status: string
  binding_name: string
  name?: string | null
  schedule: Record<string, unknown> | null
  timezone?: string | null
  payload?: Record<string, unknown> | null
  delivery?: { signal_channel_id?: string; provider_thread_id?: string } | null
  idempotency_key?: string
  next_fire_at?: string | null
  last_fire_at?: string | null
}

type ScheduledEventRow = {
  id: number
  kind: string
  status: string
  binding_name?: string | null
  due_at?: string | null
  fired_at?: string | null
  cancelled_at?: string | null
  last_fire_error?: Record<string, unknown> | null
  wake_payload?: Record<string, unknown> | null
}

export function SchedulesListPage() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const [searchParams, setSearchParams] = useSearchParams()
  const [query, setQuery] = useState('')
  const [tab, setTab] = useState('cron')

  const agents = useQuery(ankoleWebAgentControllerIndexOptions())
  const agentList = agents.data?.agents ?? []
  const agentUID = searchParams.get('agent') ?? agentList[0]?.uid ?? ''

  const sessions = useQuery({
    ...ankoleWebAgentSessionControllerIndexOptions({ path: { agent_uid: agentUID } }),
    enabled: Boolean(agentUID)
  })
  const sessionList = sessions.data?.sessions ?? []
  const sessionID = searchParams.get('session') ?? sessionList[0]?.session_id ?? ''

  const scopeReady = Boolean(agentUID && sessionID)

  const crons = useQuery({
    ...ankoleWebScheduleControllerIndexCronOptions({ path: { agent_uid: agentUID, session_id: sessionID } }),
    enabled: scopeReady
  })
  const checkbacks = useQuery({
    ...ankoleWebScheduleControllerIndexCheckbacksOptions({ path: { agent_uid: agentUID, session_id: sessionID } }),
    enabled: scopeReady
  })

  const deferredQuery = query
  const cronRows = (crons.data?.cron_schedules ?? [])
    .map(row => row as CronScheduleRow)
    .filter(row =>
      matchesResourceSearch(deferredQuery, row.name, row.binding_name, row.status, describeSchedule(row.schedule))
    )
  const checkbackRows = (checkbacks.data?.schedule_events ?? [])
    .map(row => row as ScheduledEventRow)
    .filter(row => matchesResourceSearch(deferredQuery, row.kind, row.status, row.binding_name))

  const invalidate = () => void queryClient.invalidateQueries()

  const pauseCron = useMutation({
    ...ankoleWebScheduleControllerPauseCronMutation(),
    onSuccess: () => {
      toast.success(t('console.schedules.paused'))
      invalidate()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const resumeCron = useMutation({
    ...ankoleWebScheduleControllerResumeCronMutation(),
    onSuccess: () => {
      toast.success(t('console.schedules.resumed'))
      invalidate()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const runCron = useMutation({
    ...ankoleWebScheduleControllerRunCronMutation(),
    onSuccess: () => {
      toast.success(t('console.schedules.ran'))
      invalidate()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const removeCron = useMutation({
    ...ankoleWebScheduleControllerRemoveCronMutation(),
    onSuccess: () => {
      toast.success(t('console.schedules.deleted'))
      invalidate()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const cancelCheckback = useMutation({
    ...ankoleWebScheduleControllerCancelCheckbackMutation(),
    onSuccess: () => {
      toast.success(t('console.schedules.cancelled'))
      invalidate()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  const selectAgent = (uid: string) => {
    const next = new URLSearchParams(uid ? { agent: uid } : {})
    setSearchParams(next)
  }
  const selectSession = (sid: string) => {
    const next = new URLSearchParams(searchParams)
    if (sid) next.set('session', sid)
    else next.delete('session')
    setSearchParams(next)
  }

  return (
    <div className="flex flex-col gap-4">
      <PageHeader title={t('console.schedules.title')} description={t('console.schedules.description')} />
      <div className="grid gap-3 md:grid-cols-[minmax(220px,1fr)_minmax(220px,1fr)_minmax(0,1fr)]">
        <div className="border border-border bg-card p-3">
          <LabeledField label={t('console.schedules.agent')}>
            <Select value={agentUID} onValueChange={value => selectAgent(String(value))}>
              <SelectTrigger className="w-full">
                <SelectValue placeholder={t('console.schedules.select_agent')} />
              </SelectTrigger>
              <SelectContent>
                {agentList.map(agent => (
                  <SelectItem key={agent.uid} value={agent.uid}>
                    {agent.uid}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </LabeledField>
        </div>
        <div className="border border-border bg-card p-3">
          <LabeledField label={t('console.schedules.session')}>
            <Select
              value={sessionID}
              onValueChange={value => selectSession(String(value))}
              disabled={!agentUID || sessionList.length === 0}>
              <SelectTrigger className="w-full">
                <SelectValue placeholder={t('console.schedules.select_session')} />
              </SelectTrigger>
              <SelectContent>
                {sessionList.map(session => (
                  <SelectItem key={session.session_id} value={session.session_id}>
                    <span className="font-mono text-xs">{session.session_id}</span>
                    {session.title ? (
                      <span className="ml-2 truncate text-muted-foreground">— {session.title}</span>
                    ) : null}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </LabeledField>
        </div>
        <ManualSessionEntry
          agentUID={agentUID}
          sessionList={sessionList}
          currentSession={sessionID}
          onSelectSession={selectSession}
        />
      </div>

      {!scopeReady ? (
        <div className="border border-border bg-card p-8 text-center text-sm text-muted-foreground">
          {t('console.schedules.select_scope_hint')}
        </div>
      ) : (
        <Tabs value={tab} onValueChange={setTab} className="w-full">
          <div className="flex items-center justify-between gap-3">
            <TabsList>
              <TabsTrigger value="cron">{t('console.schedules.cron_tab')}</TabsTrigger>
              <TabsTrigger value="checkbacks">{t('console.schedules.checkbacks_tab')}</TabsTrigger>
            </TabsList>
            <div className="flex items-center gap-2">
              {tab === 'cron' ? (
                <Link
                  to={`new?agent=${encodeURIComponent(agentUID)}&session=${encodeURIComponent(sessionID)}`}
                  className={buttonVariants({ size: 'sm' })}>
                  {t('console.schedules.new')}
                </Link>
              ) : null}
            </div>
          </div>

          <TabsContent value="cron">
            <CronScheduleTable
              rows={cronRows}
              agentUID={agentUID}
              sessionID={sessionID}
              isLoading={crons.isLoading}
              isFiltered={Boolean(query.trim())}
              error={crons.error}
              onSearch={setQuery}
              searchValue={query}
              onToggle={row => {
                if (row.status === 'paused') {
                  resumeCron.mutate({ path: { agent_uid: agentUID, session_id: sessionID, cron_schedule_id: row.id } })
                } else {
                  pauseCron.mutate({ path: { agent_uid: agentUID, session_id: sessionID, cron_schedule_id: row.id } })
                }
              }}
              onRun={row =>
                runCron.mutate({ path: { agent_uid: agentUID, session_id: sessionID, cron_schedule_id: row.id } })
              }
              onRemove={row =>
                removeCron.mutate({ path: { agent_uid: agentUID, session_id: sessionID, cron_schedule_id: row.id } })
              }
              togglePending={pauseCron.isPending || resumeCron.isPending}
              runPending={runCron.isPending}
              removePending={removeCron.isPending}
            />
          </TabsContent>

          <TabsContent value="checkbacks">
            <CheckbackTable
              rows={checkbackRows}
              agentUID={agentUID}
              sessionID={sessionID}
              isLoading={checkbacks.isLoading}
              isFiltered={Boolean(query.trim())}
              error={checkbacks.error}
              onSearch={setQuery}
              searchValue={query}
              onCancel={row =>
                cancelCheckback.mutate({
                  path: { agent_uid: agentUID, session_id: sessionID, scheduled_event_id: row.id }
                })
              }
              cancelPending={cancelCheckback.isPending}
            />
          </TabsContent>
        </Tabs>
      )}
    </div>
  )
}

function CronScheduleTable(props: {
  rows: CronScheduleRow[]
  agentUID: string
  sessionID: string
  isLoading: boolean
  isFiltered: boolean
  error: unknown
  onSearch: (value: string) => void
  searchValue: string
  onToggle: (row: CronScheduleRow) => void
  onRun: (row: CronScheduleRow) => void
  onRemove: (row: CronScheduleRow) => void
  togglePending: boolean
  runPending: boolean
  removePending: boolean
}) {
  const { t } = useTranslation()
  const { rows, isLoading, isFiltered, error } = props

  return (
    <div className="border border-border bg-card">
      <div className="flex items-center justify-between gap-3 border-b border-border p-3">
        <input
          className="h-9 w-full max-w-sm rounded-sm border border-border bg-background px-3 text-sm"
          placeholder={t('console.schedules.search_placeholder')}
          value={props.searchValue}
          onChange={event => props.onSearch(event.target.value)}
        />
      </div>
      {error ? <p className="p-3 text-sm text-destructive">{requestErrorMessage(error)}</p> : null}
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>{t('console.schedules.name')}</TableHead>
            <TableHead>{t('console.schedules.schedule')}</TableHead>
            <TableHead>{t('console.schedules.next_fire')}</TableHead>
            <TableHead>{t('console.schedules.last_fire')}</TableHead>
            <TableHead>{t('console.schedules.state')}</TableHead>
            <TableHead className="text-right">{t('console.actions')}</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {isLoading ? (
            <TableRow>
              <TableCell colSpan={6} className="py-8 text-center text-sm text-muted-foreground">
                {t('common.loading')}
              </TableCell>
            </TableRow>
          ) : rows.length === 0 ? (
            <TableRow>
              <TableCell colSpan={6} className="py-8 text-center text-sm text-muted-foreground">
                {isFiltered ? t('console.empty.no_results_title') : t('console.schedules.empty_title')}
              </TableCell>
            </TableRow>
          ) : (
            rows.map(row => {
              const editTo = `new?agent=${encodeURIComponent(props.agentUID)}&session=${encodeURIComponent(props.sessionID)}&cron=${encodeURIComponent(row.id)}`
              return (
                <TableRow key={row.id}>
                  <TableCell className="font-mono text-xs">
                    <Link className="text-foreground hover:text-primary hover:underline" to={editTo}>
                      {row.name || row.binding_name}
                    </Link>
                    <div className="text-muted-foreground">{row.binding_name}</div>
                  </TableCell>
                  <TableCell className="text-xs">
                    <span className="font-mono">{describeSchedule(row.schedule)}</span>
                    {row.timezone ? <div className="text-muted-foreground">{row.timezone}</div> : null}
                  </TableCell>
                  <TableCell className="text-xs">{formatConsoleDate(row.next_fire_at)}</TableCell>
                  <TableCell className="text-xs">{formatConsoleDate(row.last_fire_at)}</TableCell>
                  <TableCell>
                    <StatusIndicator tone={statusTone(row.status)}>{row.status}</StatusIndicator>
                  </TableCell>
                  <TableCell className="text-right">
                    <div className="flex items-center justify-end gap-1">
                      <Button
                        size="sm"
                        variant="ghost"
                        type="button"
                        disabled={props.runPending || row.status === 'deleted'}
                        onClick={() => props.onRun(row)}>
                        {t('console.schedules.run_now')}
                      </Button>
                      <Button
                        size="sm"
                        variant="ghost"
                        type="button"
                        disabled={props.togglePending || (row.status !== 'active' && row.status !== 'paused')}
                        onClick={() => props.onToggle(row)}>
                        {row.status === 'paused' ? t('console.schedules.resume') : t('console.schedules.pause')}
                      </Button>
                      <RowActions
                        editTo={editTo}
                        editLabel={t('common.edit')}
                        deletePending={props.removePending}
                        deleteConfirm={{
                          title: t('console.schedules.delete_title'),
                          description: t('console.schedules.delete_description', {
                            name: row.name || row.binding_name
                          }),
                          confirmLabel: t('common.delete')
                        }}
                        onDelete={() => props.onRemove(row)}
                      />
                    </div>
                  </TableCell>
                </TableRow>
              )
            })
          )}
        </TableBody>
      </Table>
    </div>
  )
}

function CheckbackTable(props: {
  rows: ScheduledEventRow[]
  agentUID: string
  sessionID: string
  isLoading: boolean
  isFiltered: boolean
  error: unknown
  onSearch: (value: string) => void
  searchValue: string
  onCancel: (row: ScheduledEventRow) => void
  cancelPending: boolean
}) {
  const { t } = useTranslation()
  const { rows, isLoading, isFiltered, error } = props

  return (
    <div className="border border-border bg-card">
      <div className="flex items-center justify-between gap-3 border-b border-border p-3">
        <input
          className="h-9 w-full max-w-sm rounded-sm border border-border bg-background px-3 text-sm"
          placeholder={t('console.schedules.search_placeholder')}
          value={props.searchValue}
          onChange={event => props.onSearch(event.target.value)}
        />
      </div>
      {error ? <p className="p-3 text-sm text-destructive">{requestErrorMessage(error)}</p> : null}
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>{t('console.schedules.due_at')}</TableHead>
            <TableHead>{t('console.schedules.kind')}</TableHead>
            <TableHead>{t('console.schedules.binding')}</TableHead>
            <TableHead>{t('console.schedules.reason')}</TableHead>
            <TableHead>{t('console.schedules.state')}</TableHead>
            <TableHead className="text-right">{t('console.actions')}</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {isLoading ? (
            <TableRow>
              <TableCell colSpan={6} className="py-8 text-center text-sm text-muted-foreground">
                {t('common.loading')}
              </TableCell>
            </TableRow>
          ) : rows.length === 0 ? (
            <TableRow>
              <TableCell colSpan={6} className="py-8 text-center text-sm text-muted-foreground">
                {isFiltered ? t('console.empty.no_results_title') : t('console.schedules.checkbacks_empty')}
              </TableCell>
            </TableRow>
          ) : (
            rows.map(row => (
              <TableRow key={row.id}>
                <TableCell className="text-xs">{formatConsoleDate(row.due_at)}</TableCell>
                <TableCell className="font-mono text-xs">{row.kind}</TableCell>
                <TableCell className="text-xs">{row.binding_name || '—'}</TableCell>
                <TableCell className="max-w-xs truncate text-xs text-muted-foreground">
                  {checkbackReason(row.wake_payload)}
                </TableCell>
                <TableCell>
                  <StatusIndicator tone={eventTone(row.status)}>{row.status}</StatusIndicator>
                </TableCell>
                <TableCell className="text-right">
                  {row.status === 'scheduled' || row.status === 'firing' ? (
                    <ConfirmDeleteButton
                      confirm={{
                        title: t('console.schedules.cancel_title'),
                        description: t('console.schedules.cancel_description'),
                        confirmLabel: t('console.schedules.cancel')
                      }}
                      pending={props.cancelPending}
                      onConfirm={() => props.onCancel(row)}
                    />
                  ) : (
                    <span className="text-xs text-muted-foreground">—</span>
                  )}
                </TableCell>
              </TableRow>
            ))
          )}
        </TableBody>
      </Table>
    </div>
  )
}

export function ScheduleCronEditorPage() {
  useSignals()
  const { t } = useTranslation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const model = useModel(ScheduleEditorModel)
  const [searchParams] = useSearchParams()

  const agentUID = searchParams.get('agent') ?? ''
  const sessionID = searchParams.get('session') ?? ''
  const cronID = searchParams.get('cron') ?? undefined
  const editing = Boolean(cronID)

  const bindings = useQuery({
    ...ankoleWebSignalBindingControllerIndexOptions({ path: { agent_uid: agentUID } }),
    enabled: Boolean(agentUID)
  })
  const bindingList = bindings.data?.signal_bindings ?? []

  const existing = useQuery({
    ...ankoleWebScheduleControllerShowCronOptions({
      path: { agent_uid: agentUID, session_id: sessionID, cron_schedule_id: cronID ?? '' }
    }),
    enabled: editing && Boolean(agentUID && sessionID && cronID)
  })
  const existingRow = (existing.data?.cron_schedule ?? null) as CronScheduleRow | null

  const runs = useQuery({
    ...ankoleWebScheduleControllerCronRunsOptions({
      path: { agent_uid: agentUID, session_id: sessionID, cron_schedule_id: cronID ?? '' }
    }),
    enabled: editing && Boolean(agentUID && sessionID && cronID)
  })
  const runRows = ((runs.data?.schedule_runs ?? []) as ScheduledEventRow[]).slice(0, 25)

  useEffect(() => {
    if (editing) {
      if (!existingRow) return
      const schedule = (existingRow.schedule ?? {}) as Record<string, unknown>
      model.initialize(`cron:${existingRow.id}`, draftFromCron(existingRow, schedule))
    } else {
      model.initialize('cron:new', emptyDraft())
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [editing, existingRow, model])

  const saveCron = useMutation({
    ...ankoleWebScheduleControllerCreateCronMutation(),
    onSuccess: () => {
      toast.success(t('console.schedules.saved'))
      void queryClient.invalidateQueries()
      navigate(`/schedules?agent=${encodeURIComponent(agentUID)}&session=${encodeURIComponent(sessionID)}`)
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const updateCron = useMutation({
    ...ankoleWebScheduleControllerUpdateCronMutation(),
    onSuccess: () => {
      toast.success(t('console.schedules.saved'))
      void queryClient.invalidateQueries()
      navigate(`/schedules?agent=${encodeURIComponent(agentUID)}&session=${encodeURIComponent(sessionID)}`)
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  const submit = () => {
    model.clearValidation()
    if (!agentUID || !sessionID) {
      model.validationError.value = t('console.schedules.scope_required')
      return
    }
    if (editing) {
      if (!cronID) return
      const body = model.toUpdateBody()
      if (!body) {
        model.validationError.value = t('console.schedules.schedule_invalid')
        return
      }
      updateCron.mutate({ body, path: { agent_uid: agentUID, session_id: sessionID, cron_schedule_id: cronID } })
      return
    }
    if (!model.idempotencyKey.value.trim()) {
      model.idempotencyKey.value = crypto.randomUUID()
    }
    const body = model.toCreateBody()
    if (!body) {
      model.validationError.value = t('console.schedules.schedule_invalid')
      return
    }
    saveCron.mutate({ body, path: { agent_uid: agentUID, session_id: sessionID } })
  }

  const backTo = `/schedules?agent=${encodeURIComponent(agentUID)}&session=${encodeURIComponent(sessionID)}`

  return (
    <div className="mx-auto flex w-full max-w-3xl flex-col gap-5">
      <PageHeader title={editing ? t('console.schedules.edit') : t('console.schedules.new')} />
      {model.validationError.value ? (
        <p className="border border-destructive bg-destructive/10 p-3 text-sm text-destructive">
          {model.validationError.value}
        </p>
      ) : null}
      {(bindings.error ?? existing.error ?? saveCron.error ?? updateCron.error) && !model.validationError.value ? (
        <p className="border border-destructive bg-destructive/10 p-3 text-sm text-destructive">
          {requestErrorMessage(bindings.error ?? existing.error ?? saveCron.error ?? updateCron.error)}
        </p>
      ) : null}

      <form
        className="flex flex-col gap-5"
        onSubmit={event => {
          event.preventDefault()
          submit()
        }}>
        <div className="grid gap-3 md:grid-cols-2">
          <LabeledField label={t('console.schedules.agent')}>
            <ReadOnlyValue mono>{agentUID || '—'}</ReadOnlyValue>
          </LabeledField>
          <LabeledField label={t('console.schedules.session')}>
            <ReadOnlyValue mono>{sessionID || '—'}</ReadOnlyValue>
          </LabeledField>
        </div>

        <div className="grid gap-3 md:grid-cols-2">
          <LabeledField label={t('console.schedules.binding')} required>
            <Select value={model.bindingName.value} onValueChange={value => (model.bindingName.value = String(value))}>
              <SelectTrigger className="w-full">
                <SelectValue placeholder={t('console.schedules.binding_placeholder')} />
              </SelectTrigger>
              <SelectContent>
                {bindingList.map(binding => (
                  <SelectItem key={`${binding.adapter}:${binding.name}`} value={binding.name}>
                    {binding.name}
                    <span className="text-muted-foreground"> ({binding.adapter})</span>
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </LabeledField>
          <LabeledField label={t('console.schedules.name')} description={t('console.schedules.name_hint')}>
            <Input value={model.name.value} onChange={event => (model.name.value = event.target.value)} />
          </LabeledField>
        </div>

        <LabeledField label={t('console.schedules.schedule_kind')}>
          <Select
            value={model.scheduleKind.value || 'cron'}
            onValueChange={value => (model.scheduleKind.value = String(value) as ScheduleKind)}>
            <SelectTrigger className="w-full md:max-w-sm">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="cron">{t('console.schedules.kind_cron')}</SelectItem>
              <SelectItem value="every">{t('console.schedules.kind_every')}</SelectItem>
            </SelectContent>
          </Select>
        </LabeledField>

        {model.scheduleKind.value === 'every' ? (
          <div className="grid gap-3 md:grid-cols-2">
            <LabeledField label={t('console.schedules.every_ms')} required>
              <Input
                type="number"
                min="1"
                value={model.everyMs.value}
                onChange={event => (model.everyMs.value = event.target.value)}
              />
            </LabeledField>
            <LabeledField label={t('console.schedules.anchor_at')} description={t('console.schedules.anchor_hint')}>
              <Input
                value={model.anchorAt.value}
                placeholder="2026-07-17T00:00:00Z"
                onChange={event => (model.anchorAt.value = event.target.value)}
              />
            </LabeledField>
          </div>
        ) : (
          <div className="grid gap-3 md:grid-cols-2">
            <LabeledField
              label={t('console.schedules.expression')}
              required
              description={t('console.schedules.expression_hint')}>
              <Input
                className="font-mono"
                placeholder="0 9 * * *"
                value={model.cronExpression.value}
                onChange={event => (model.cronExpression.value = event.target.value)}
              />
            </LabeledField>
            <LabeledField label={t('console.schedules.timezone')} description={t('console.schedules.timezone_hint')}>
              <Input
                placeholder="Asia/Shanghai"
                value={model.timezone.value}
                onChange={event => (model.timezone.value = event.target.value)}
              />
            </LabeledField>
          </div>
        )}

        <div className="grid gap-3 md:grid-cols-2">
          <LabeledField label={t('console.schedules.delivery_channel')} required>
            <Input
              value={model.deliveryChannelId.value}
              onChange={event => (model.deliveryChannelId.value = event.target.value)}
            />
          </LabeledField>
          <LabeledField label={t('console.schedules.delivery_thread')}>
            <Input
              value={model.deliveryThreadId.value}
              onChange={event => (model.deliveryThreadId.value = event.target.value)}
            />
          </LabeledField>
        </div>

        {!editing ? (
          <LabeledField
            label={t('console.schedules.idempotency_key')}
            description={t('console.schedules.idempotency_hint')}>
            <Input
              value={model.idempotencyKey.value}
              placeholder={t('console.schedules.idempotency_placeholder')}
              onChange={event => (model.idempotencyKey.value = event.target.value)}
            />
          </LabeledField>
        ) : null}

        {!editing ? (
          <LabeledField label={t('console.schedules.status_field')}>
            <Select
              value={model.status.value || 'active'}
              onValueChange={value => (model.status.value = String(value) as CronStatus)}>
              <SelectTrigger className="w-full md:max-w-sm">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="active">{t('console.status.active')}</SelectItem>
                <SelectItem value="paused">{t('console.schedules.paused_status')}</SelectItem>
              </SelectContent>
            </Select>
          </LabeledField>
        ) : null}

        <div className="flex items-center justify-end gap-2">
          <Button type="button" variant="ghost" onClick={() => navigate(backTo)}>
            {t('common.cancel')}
          </Button>
          <Button type="submit" disabled={saveCron.isPending || updateCron.isPending}>
            {t('common.save')}
          </Button>
        </div>
      </form>

      {editing ? (
        <div className="flex flex-col gap-3">
          <h3 className="text-sm font-medium">{t('console.schedules.run_history')}</h3>
          {runRows.length === 0 ? (
            <p className="text-sm text-muted-foreground">{t('console.schedules.no_runs')}</p>
          ) : (
            <div className="border border-border">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>{t('console.schedules.due_at')}</TableHead>
                    <TableHead>{t('console.schedules.state')}</TableHead>
                    <TableHead>{t('console.schedules.fired_at')}</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {runRows.map(row => (
                    <TableRow key={row.id}>
                      <TableCell className="text-xs">{formatConsoleDate(row.due_at)}</TableCell>
                      <TableCell>
                        <StatusIndicator tone={eventTone(row.status)}>{row.status}</StatusIndicator>
                      </TableCell>
                      <TableCell className="text-xs">{formatConsoleDate(row.fired_at)}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
          )}
        </div>
      ) : null}
    </div>
  )
}

// Manual session entry fallback. Session IDs are opaque caller-chosen strings;
// when the enumerated dropdown is empty the operator can paste a known key.
function ManualSessionEntry(props: {
  agentUID: string
  sessionList: { session_id: string }[]
  currentSession: string
  onSelectSession: (sid: string) => void
}) {
  const { t } = useTranslation()
  const [manual, setManual] = useState(false)
  const [value, setValue] = useState('')
  const dropdownEmpty = props.sessionList.length === 0

  if (!dropdownEmpty && !manual) {
    return (
      <div className="border border-border bg-card p-3">
        <LabeledField label={t('console.schedules.manual_session')}>
          <Switch checked={manual} onCheckedChange={setManual} />
        </LabeledField>
      </div>
    )
  }

  return (
    <div className="border border-border bg-card p-3">
      <LabeledField
        label={t('console.schedules.manual_session')}
        description={t('console.schedules.manual_session_hint')}>
        <div className="flex gap-2">
          <Input
            className="font-mono text-xs"
            placeholder="job:<id> or <session-id>"
            value={value || props.currentSession}
            onChange={event => setValue(event.target.value)}
          />
          <Button type="button" size="sm" disabled={!value.trim()} onClick={() => props.onSelectSession(value.trim())}>
            {t('console.schedules.use_session')}
          </Button>
        </div>
      </LabeledField>
    </div>
  )
}

// --- helpers ---

function describeSchedule(schedule: Record<string, unknown> | null | undefined): string {
  if (!schedule || typeof schedule !== 'object') return '—'
  const kind = String((schedule as { kind?: unknown }).kind ?? '')
  if (kind === 'cron') return String((schedule as { expression?: unknown }).expression ?? '—')
  if (kind === 'every') {
    const ms = Number((schedule as { every_ms?: unknown }).every_ms)
    if (!Number.isFinite(ms) || ms <= 0) return 'every ?'
    if (ms >= 86_400_000 && ms % 86_400_000 === 0) return `every ${ms / 86_400_000}d`
    if (ms >= 3_600_000 && ms % 3_600_000 === 0) return `every ${ms / 3_600_000}h`
    if (ms >= 60_000 && ms % 60_000 === 0) return `every ${ms / 60_000}m`
    return `every ${ms}ms`
  }
  return kind || '—'
}

function checkbackReason(payload: Record<string, unknown> | null | undefined): string {
  if (!payload) return '—'
  const reason = (payload as { reason?: unknown }).reason
  return typeof reason === 'string' ? reason : '—'
}

function statusTone(status: string): 'positive' | 'warning' | 'neutral' | 'danger' {
  switch (status) {
    case 'active':
      return 'positive'
    case 'paused':
      return 'warning'
    case 'deleted':
      return 'neutral'
    case 'failed':
      return 'danger'
    default:
      return 'neutral'
  }
}

function eventTone(status: string): 'positive' | 'warning' | 'neutral' | 'danger' | 'info' {
  switch (status) {
    case 'fired':
      return 'positive'
    case 'scheduled':
      return 'info'
    case 'firing':
      return 'warning'
    case 'cancelled':
      return 'neutral'
    case 'failed':
      return 'danger'
    default:
      return 'neutral'
  }
}

function draftFromCron(row: CronScheduleRow, schedule: Record<string, unknown>): ScheduleEditorDraft {
  const kind = (String(schedule.kind ?? 'cron') || 'cron') as ScheduleKind
  const delivery = row.delivery ?? {}
  return {
    bindingName: row.binding_name,
    name: row.name ?? '',
    status: (row.status === 'paused' ? 'paused' : 'active') as CronStatus,
    scheduleKind: kind,
    cronExpression: String(schedule.expression ?? ''),
    everyMs: String(schedule.every_ms ?? ''),
    anchorAt: String(schedule.anchor_at ?? ''),
    timezone: row.timezone ?? '',
    staggerMs: String(schedule.stagger_ms ?? '0'),
    deliveryChannelId: delivery.signal_channel_id ?? '',
    deliveryThreadId: delivery.provider_thread_id ?? '',
    payload: safeStringify(row.payload ?? {}),
    idempotencyKey: row.idempotency_key ?? ''
  }
}

function emptyDraft(): ScheduleEditorDraft {
  return {
    bindingName: '',
    name: '',
    status: 'active',
    scheduleKind: 'cron',
    cronExpression: '',
    everyMs: '',
    anchorAt: '',
    timezone: '',
    staggerMs: '0',
    deliveryChannelId: '',
    deliveryThreadId: '',
    payload: '{}',
    idempotencyKey: ''
  }
}

function safeStringify(value: unknown): string {
  try {
    return JSON.stringify(value, null, 2)
  } catch {
    return '{}'
  }
}
