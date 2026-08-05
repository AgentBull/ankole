import {
  Button,
  buttonVariants,
  Input,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
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
import { AgentFilter, useAgentScope } from '../console-agent-scope'
import { PageHeader, PageStack, RefreshButton } from '../console-page'
import { formatConsoleDate } from '../console-primitives'
import {
  ConfirmDeleteButton,
  LabeledField,
  ReadOnlyValue,
  SaveButton,
  StatusIndicator,
  useFormCompleteness
} from '../console-form'
import { FilterSwitch, ResourceSearch, RowActions, ScopeBar } from '../console-list-page'
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
  session_id: string
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
  session_id: string
  binding_name?: string | null
  due_at?: string | null
  fired_at?: string | null
  cancelled_at?: string | null
  last_fire_error?: Record<string, unknown> | null
  wake_payload?: Record<string, unknown> | null
}

/** A pending checkback still has a wake edge ahead of it; the rest are history. */
function pending(row: ScheduledEventRow): boolean {
  return row.status === 'scheduled' || row.status === 'firing'
}

export function SchedulesListPage() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const [query, setQuery] = useState('')
  const [includeFinished, setIncludeFinished] = useState(false)
  const [tab, setTab] = useState('cron')
  const scope = useAgentScope()
  const scopeReady = Boolean(scope.agentUID)

  const crons = useQuery({
    ...ankoleWebScheduleControllerIndexCronOptions({ path: { agent_uid: scope.agentUID } }),
    enabled: scopeReady
  })
  const checkbacks = useQuery({
    ...ankoleWebScheduleControllerIndexCheckbacksOptions({ path: { agent_uid: scope.agentUID } }),
    enabled: scopeReady
  })

  const cronRows = (crons.data?.cron_schedules ?? [])
    .map(row => row as CronScheduleRow)
    .filter(row =>
      matchesResourceSearch(
        query,
        row.name,
        row.binding_name,
        row.session_id,
        row.status,
        describeSchedule(row.schedule)
      )
    )
  const checkbackRows = (checkbacks.data?.schedule_events ?? [])
    .map(row => row as ScheduledEventRow)
    .filter(row => includeFinished || pending(row))
    .filter(row => matchesResourceSearch(query, row.kind, row.status, row.session_id, row.binding_name))

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

  return (
    <PageStack>
      <PageHeader
        title={t('console.schedules.title')}
        description={t('console.schedules.description')}
        actions={<RefreshButton />}
      />

      <ScopeBar>
        <AgentFilter scope={scope} />
        {tab === 'checkbacks' ? (
          <FilterSwitch checked={includeFinished} label={t('console.include_finished')} onChange={setIncludeFinished} />
        ) : null}
      </ScopeBar>

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
                <Link to={`new?agent=${encodeURIComponent(scope.agentUID)}`} className={buttonVariants({ size: 'sm' })}>
                  {t('console.schedules.new')}
                </Link>
              ) : null}
            </div>
          </div>

          <ResourceSearch label={t('console.schedules.search_placeholder')} value={query} onChange={setQuery} />

          <TabsContent value="cron">
            <CronScheduleTable
              rows={cronRows}
              agentUID={scope.agentUID}
              isLoading={crons.isLoading}
              isFiltered={Boolean(query.trim())}
              error={crons.error}
              onClearFilters={() => setQuery('')}
              onToggle={row => {
                if (row.status === 'paused') {
                  resumeCron.mutate({ path: { agent_uid: scope.agentUID, cron_schedule_id: row.id } })
                } else {
                  pauseCron.mutate({ path: { agent_uid: scope.agentUID, cron_schedule_id: row.id } })
                }
              }}
              onRun={row =>
                runCron.mutate({
                  headers: { 'Idempotency-Key': crypto.randomUUID() },
                  path: { agent_uid: scope.agentUID, cron_schedule_id: row.id }
                })
              }
              onRemove={row => removeCron.mutate({ path: { agent_uid: scope.agentUID, cron_schedule_id: row.id } })}
              togglePending={pauseCron.isPending || resumeCron.isPending}
              runPending={runCron.isPending}
              removePending={removeCron.isPending}
            />
          </TabsContent>

          <TabsContent value="checkbacks">
            <CheckbackTable
              rows={checkbackRows}
              isLoading={checkbacks.isLoading}
              isFiltered={Boolean(query.trim())}
              error={checkbacks.error}
              onClearFilters={() => setQuery('')}
              onCancel={row =>
                cancelCheckback.mutate({
                  path: { agent_uid: scope.agentUID, scheduled_event_id: row.id }
                })
              }
              cancelPending={cancelCheckback.isPending}
            />
          </TabsContent>
        </Tabs>
      )}
    </PageStack>
  )
}

function CronScheduleTable(props: {
  rows: CronScheduleRow[]
  agentUID: string
  isLoading: boolean
  isFiltered: boolean
  error: unknown
  onClearFilters: () => void
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
      {error ? <p className="p-3 text-sm text-destructive">{requestErrorMessage(error)}</p> : null}
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>{t('console.schedules.name')}</TableHead>
            <TableHead>{t('console.session')}</TableHead>
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
              <TableCell colSpan={7} className="py-8 text-center text-sm text-muted-foreground">
                {t('common.loading')}
              </TableCell>
            </TableRow>
          ) : rows.length === 0 ? (
            <TableRow>
              <TableCell colSpan={7} className="py-8 text-center text-sm text-muted-foreground">
                <div className="grid justify-items-center gap-3">
                  <span>{isFiltered ? t('console.empty.no_results_title') : t('console.schedules.empty_title')}</span>
                  {isFiltered ? (
                    <Button size="sm" type="button" variant="outline" onClick={props.onClearFilters}>
                      {t('console.empty.clear_filters')}
                    </Button>
                  ) : null}
                </div>
              </TableCell>
            </TableRow>
          ) : (
            rows.map(row => {
              const editTo = `new?agent=${encodeURIComponent(props.agentUID)}&cron=${encodeURIComponent(row.id)}`
              return (
                <TableRow key={row.id}>
                  <TableCell className="font-mono text-xs">
                    <Link className="text-foreground hover:text-link hover:underline" to={editTo}>
                      {row.name || row.binding_name}
                    </Link>
                    <div className="text-muted-foreground">{row.binding_name}</div>
                  </TableCell>
                  <TableCell>
                    <span className="block max-w-56 truncate font-mono text-xs" title={row.session_id}>
                      {row.session_id}
                    </span>
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
  isLoading: boolean
  isFiltered: boolean
  error: unknown
  onClearFilters: () => void
  onCancel: (row: ScheduledEventRow) => void
  cancelPending: boolean
}) {
  const { t } = useTranslation()
  const { rows, isLoading, isFiltered, error } = props

  return (
    <div className="border border-border bg-card">
      {error ? <p className="p-3 text-sm text-destructive">{requestErrorMessage(error)}</p> : null}
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>{t('console.schedules.due_at')}</TableHead>
            <TableHead>{t('console.session')}</TableHead>
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
              <TableCell colSpan={7} className="py-8 text-center text-sm text-muted-foreground">
                {t('common.loading')}
              </TableCell>
            </TableRow>
          ) : rows.length === 0 ? (
            <TableRow>
              <TableCell colSpan={7} className="py-8 text-center text-sm text-muted-foreground">
                <div className="grid justify-items-center gap-3">
                  <span>
                    {isFiltered ? t('console.empty.no_results_title') : t('console.schedules.checkbacks_empty')}
                  </span>
                  {isFiltered ? (
                    <Button size="sm" type="button" variant="outline" onClick={props.onClearFilters}>
                      {t('console.empty.clear_filters')}
                    </Button>
                  ) : null}
                </div>
              </TableCell>
            </TableRow>
          ) : (
            rows.map(row => (
              <TableRow key={row.id}>
                <TableCell className="text-xs">{formatConsoleDate(row.due_at)}</TableCell>
                <TableCell>
                  <span className="block max-w-56 truncate font-mono text-xs" title={row.session_id}>
                    {row.session_id}
                  </span>
                </TableCell>
                <TableCell className="font-mono text-xs">{row.kind}</TableCell>
                <TableCell className="text-xs">{row.binding_name || '—'}</TableCell>
                <TableCell className="max-w-xs truncate text-xs text-muted-foreground">
                  {checkbackReason(row.wake_payload)}
                </TableCell>
                <TableCell>
                  <StatusIndicator tone={eventTone(row.status)}>{row.status}</StatusIndicator>
                </TableCell>
                <TableCell className="text-right">
                  {pending(row) ? (
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
  const formCompleteness = useFormCompleteness()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const model = useModel(ScheduleEditorModel)
  const [searchParams] = useSearchParams()

  const agentUID = searchParams.get('agent') ?? ''
  const cronID = searchParams.get('cron') ?? undefined
  const editing = Boolean(cronID)

  const bindings = useQuery({
    ...ankoleWebSignalBindingControllerIndexOptions({ path: { agent_uid: agentUID } }),
    enabled: Boolean(agentUID)
  })
  const bindingList = bindings.data?.signal_bindings ?? []

  // Session ids are opaque caller-chosen strings, so a new schedule needs one
  // typed in. The enumerated list is a convenience, not the full set.
  const sessions = useQuery({
    ...ankoleWebAgentSessionControllerIndexOptions({ path: { agent_uid: agentUID } }),
    enabled: !editing && Boolean(agentUID)
  })
  const sessionList = sessions.data?.sessions ?? []

  const existing = useQuery({
    ...ankoleWebScheduleControllerShowCronOptions({
      path: { agent_uid: agentUID, cron_schedule_id: cronID ?? '' }
    }),
    enabled: editing && Boolean(agentUID && cronID)
  })
  const existingRow = (existing.data?.cron_schedule ?? null) as CronScheduleRow | null

  const runs = useQuery({
    ...ankoleWebScheduleControllerCronRunsOptions({
      path: { agent_uid: agentUID, cron_schedule_id: cronID ?? '' }
    }),
    enabled: editing && Boolean(agentUID && cronID)
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
      navigate(backTo)
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const updateCron = useMutation({
    ...ankoleWebScheduleControllerUpdateCronMutation(),
    onSuccess: () => {
      toast.success(t('console.schedules.saved'))
      void queryClient.invalidateQueries()
      navigate(backTo)
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  const submit = () => {
    model.clearValidation()
    if (!agentUID) {
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
      if (Object.keys(body).length === 0) {
        navigate(backTo)
        return
      }
      updateCron.mutate({ body, path: { agent_uid: agentUID, cron_schedule_id: cronID } })
      return
    }
    if (!model.sessionId.value.trim()) {
      model.validationError.value = t('console.schedules.session_required')
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
    saveCron.mutate({ body, path: { agent_uid: agentUID } })
  }

  const backTo = `/schedules?agent=${encodeURIComponent(agentUID)}`
  const updateBody = editing ? model.toUpdateBody() : undefined
  const unchanged = Boolean(editing && updateBody && Object.keys(updateBody).length === 0)
  const submitting = saveCron.isPending || updateCron.isPending
  const submitUnavailable = Boolean(editing && !existingRow)
  const submitDisabled = submitting || submitUnavailable || (unchanged && !formCompleteness.incomplete)

  return (
    <PageStack className="mx-auto w-full max-w-3xl">
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
        ref={formCompleteness.formRef}
        className="flex flex-col gap-5"
        noValidate
        onChange={formCompleteness.refresh}
        onInput={formCompleteness.refresh}
        onSubmit={event => {
          event.preventDefault()
          submit()
        }}>
        <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
          <LabeledField label={t('console.agents.agent')}>
            <ReadOnlyValue mono>{agentUID || '—'}</ReadOnlyValue>
          </LabeledField>
          {editing ? (
            <LabeledField label={t('console.session')}>
              <ReadOnlyValue mono>{model.sessionId.value || '—'}</ReadOnlyValue>
            </LabeledField>
          ) : (
            <LabeledField label={t('console.session')} required description={t('console.schedules.session_hint')}>
              <Input
                className="font-mono text-xs"
                list="schedule-session-options"
                placeholder="job:<id> or <session-id>"
                value={model.sessionId.value}
                onChange={event => (model.sessionId.value = event.target.value)}
              />
              <datalist id="schedule-session-options">
                {sessionList.map(session => (
                  <option key={session.session_id} value={session.session_id}>
                    {session.title ?? undefined}
                  </option>
                ))}
              </datalist>
            </LabeledField>
          )}
        </div>

        <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
          <LabeledField label={t('console.schedules.binding')} required>
            <Select value={model.bindingName.value} onValueChange={value => (model.bindingName.value = String(value))}>
              <SelectTrigger className="w-full">
                <SelectValue placeholder={t('console.schedules.binding_placeholder')} />
              </SelectTrigger>
              <SelectContent emptyLabel={t('common.select_empty')}>
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
          <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
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
          <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
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

        <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
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
          <SaveButton
            type="submit"
            disabled={submitDisabled}
            incomplete={formCompleteness.incomplete && !submitting && !submitUnavailable}
            loading={submitting}
            title={unchanged ? t('common.save_disabled') : undefined}>
            {t('common.save')}
          </SaveButton>
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
    </PageStack>
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
    case 'completed':
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
    sessionId: row.session_id,
    bindingName: row.binding_name,
    name: row.name ?? '',
    status: (row.status === 'paused' ? 'paused' : 'active') as CronStatus,
    scheduleKind: kind,
    cronExpression: String(schedule.expression ?? ''),
    everyMs: String(schedule.every_ms ?? ''),
    anchorAt: String(schedule.anchor_at ?? ''),
    timezone: row.timezone ?? '',
    deliveryChannelId: delivery.signal_channel_id ?? '',
    deliveryThreadId: delivery.provider_thread_id ?? '',
    payload: safeStringify(row.payload ?? {}),
    idempotencyKey: row.idempotency_key ?? ''
  }
}

function emptyDraft(): ScheduleEditorDraft {
  return {
    sessionId: '',
    bindingName: '',
    name: '',
    status: 'active',
    scheduleKind: 'cron',
    cronExpression: '',
    everyMs: '',
    anchorAt: '',
    timezone: '',
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
