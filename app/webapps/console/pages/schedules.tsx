import { LIST_REFRESH_MS } from '../refresh-intervals'
import {
  Button,
  CreatableCombobox,
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
  Textarea,
  toast
} from '@ankole/uikit'
import {
  RiCalendarScheduleLine,
  RiCloseCircleLine,
  RiPauseCircleLine,
  RiPlayCircleLine,
  RiTimerLine
} from '@remixicon/react'
import type { TFunction } from 'i18next'
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
import { AgentFilter, resolveAgentUID, useAgentScope, type AgentScope } from '../console-agent-scope'
import { ErrorBlock } from '../../common/error-block'
import { formatConsoleDate } from '../console-primitives'
import { ConfirmDeleteButton, LabeledField, ReadOnlyValue, ResourceEditorPage, StatusIndicator } from '../console-form'
import { AgentCell, FilterSwitch, ResourceListPage, ResourceSearch, RowActions, SubNav } from '../console-list-page'
import {
  deliveryTargetDrafts,
  isMutableCronStatus,
  scheduleOccurrenceBound,
  ScheduleEditorModel,
  type CronDeliveryProjection,
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
  agent_uid: string
  owner_session_id: string
  execution_session_id: string
  binding_name: string
  name?: string | null
  schedule: Record<string, unknown> | null
  timezone?: string | null
  payload?: Record<string, unknown> | null
  delivery?: CronDeliveryProjection | null
  automation_job_id?: number | null
  idempotency_key?: string
  next_fire_at?: string | null
  last_fire_at?: string | null
}

type ScheduledEventRow = {
  id: number
  kind: string
  status: string
  agent_uid: string
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
  const scope = useAgentScope()

  const crons = useQuery({
    ...ankoleWebScheduleControllerIndexCronOptions({ query: { agent: scope.agentUID || undefined } }),
    refetchInterval: LIST_REFRESH_MS
  })

  const rows = ((crons.data?.cron_schedules ?? []) as CronScheduleRow[]).filter(row =>
    matchesResourceSearch(
      query,
      row.name,
      row.binding_name,
      row.agent_uid,
      row.owner_session_id,
      row.status,
      scheduleStatusLabel(t, row.status),
      describeSchedule(t, row.schedule)
    )
  )

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

  return (
    <ResourceListPage
      title={t('console.schedules.title')}
      description={t('console.schedules.description')}
      columns={[
        t('console.schedules.name'),
        t('console.agents.agent'),
        t('console.schedules.owner_session'),
        t('console.schedules.schedule'),
        t('console.schedules.next_fire'),
        t('console.schedules.last_fire'),
        t('console.schedules.state')
      ]}
      count={rows.length}
      createTo={
        scope.agents.length > 0
          ? scope.agentUID
            ? `new?agent=${encodeURIComponent(scope.agentUID)}`
            : 'new'
          : undefined
      }
      createLabel={t('console.schedules.new')}
      emptyIcon={<RiCalendarScheduleLine aria-hidden />}
      emptyTitle={t('console.schedules.empty_title')}
      error={crons.error}
      isEmpty={rows.length === 0}
      isFiltered={Boolean(query.trim())}
      isLoading={crons.isLoading}
      onClearFilters={() => setQuery('')}
      subNav={<ScheduleTabs scope={scope} />}
      toolbarCanRevealRows
      toolbar={
        <ResourceSearch
          label={t('console.schedules.search')}
          placeholder={t('console.schedules.search_placeholder')}
          value={query}
          onChange={setQuery}
          filters={<AgentFilter scope={scope} />}
        />
      }>
      {rows.map(row => {
        const editTo = `new?agent=${encodeURIComponent(row.agent_uid)}&cron=${encodeURIComponent(row.id)}`
        const toggleable = isMutableCronStatus(row.status)
        return (
          <TableRow key={`${row.agent_uid}:${row.id}`}>
            <TableCell className="font-mono text-xs">
              <Link className="text-foreground hover:text-link hover:underline" to={editTo}>
                {row.name || row.binding_name}
              </Link>
              <div className="text-muted-foreground">{row.binding_name}</div>
            </TableCell>
            <AgentCell uid={row.agent_uid} />
            <TableCell>
              <span className="block max-w-56 truncate font-mono text-xs" title={row.owner_session_id}>
                {row.owner_session_id}
              </span>
            </TableCell>
            <TableCell className="text-xs">
              <span className="font-mono">{describeSchedule(t, row.schedule)}</span>
              {row.timezone ? <div className="text-muted-foreground">{row.timezone}</div> : null}
            </TableCell>
            <TableCell className="text-xs">{formatConsoleDate(row.next_fire_at)}</TableCell>
            <TableCell className="text-xs">{formatConsoleDate(row.last_fire_at)}</TableCell>
            <TableCell>
              <StatusIndicator tone={statusTone(row.status)}>{scheduleStatusLabel(t, row.status)}</StatusIndicator>
            </TableCell>
            <RowActions
              editTo={editTo}
              editLabel={t('common.edit')}
              actions={[
                ...(toggleable
                  ? [
                      {
                        icon: <RiPlayCircleLine />,
                        label: t('console.schedules.run_now'),
                        pending: runCron.isPending,
                        onAction: () =>
                          runCron.mutate({
                            headers: { 'Idempotency-Key': crypto.randomUUID() },
                            path: { agent_uid: row.agent_uid, cron_schedule_id: row.id }
                          })
                      }
                    ]
                  : []),
                ...(toggleable
                  ? [
                      {
                        icon: row.status === 'paused' ? <RiPlayCircleLine /> : <RiPauseCircleLine />,
                        label: row.status === 'paused' ? t('console.schedules.resume') : t('console.schedules.pause'),
                        pending: pauseCron.isPending || resumeCron.isPending,
                        onAction: () => {
                          const path = { agent_uid: row.agent_uid, cron_schedule_id: row.id }
                          if (row.status === 'paused') resumeCron.mutate({ path })
                          else pauseCron.mutate({ path })
                        }
                      }
                    ]
                  : [])
              ]}
              deletePending={removeCron.isPending}
              deleteConfirm={{
                title: t('console.schedules.delete_title'),
                description: t('console.schedules.delete_description', { name: row.name || row.binding_name }),
                confirmLabel: t('common.delete')
              }}
              onDelete={() => removeCron.mutate({ path: { agent_uid: row.agent_uid, cron_schedule_id: row.id } })}
            />
          </TableRow>
        )
      })}
    </ResourceListPage>
  )
}

export function ScheduleCheckbacksPage() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const [query, setQuery] = useState('')
  const [includeFinished, setIncludeFinished] = useState(false)
  const scope = useAgentScope()

  const checkbacks = useQuery({
    ...ankoleWebScheduleControllerIndexCheckbacksOptions({ query: { agent: scope.agentUID || undefined } }),
    refetchInterval: LIST_REFRESH_MS
  })

  const rows = (checkbacks.data?.schedule_events ?? [])
    .map(row => row as ScheduledEventRow)
    .filter(row => includeFinished || pending(row))
    .filter(row =>
      matchesResourceSearch(
        query,
        row.kind,
        row.status,
        eventStatusLabel(t, row.status),
        row.agent_uid,
        row.session_id,
        row.binding_name
      )
    )

  const cancelCheckback = useMutation({
    ...ankoleWebScheduleControllerCancelCheckbackMutation(),
    onSuccess: () => {
      toast.success(t('console.schedules.cancelled'))
      void queryClient.invalidateQueries()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  return (
    <ResourceListPage
      title={t('console.schedules.title')}
      description={t('console.schedules.description')}
      columns={[
        t('console.schedules.due_at'),
        t('console.agents.agent'),
        t('console.session'),
        t('console.schedules.kind'),
        t('console.schedules.binding'),
        t('console.schedules.reason'),
        t('console.schedules.state')
      ]}
      count={rows.length}
      emptyIcon={<RiTimerLine aria-hidden />}
      emptyTitle={t('console.schedules.checkbacks_empty')}
      error={checkbacks.error}
      isEmpty={rows.length === 0}
      isFiltered={Boolean(query.trim())}
      isLoading={checkbacks.isLoading}
      onClearFilters={() => setQuery('')}
      subNav={<ScheduleTabs scope={scope} />}
      toolbarCanRevealRows
      toolbar={
        <ResourceSearch
          label={t('console.schedules.search')}
          placeholder={t('console.schedules.search_placeholder')}
          value={query}
          onChange={setQuery}
          filters={
            <>
              <AgentFilter scope={scope} />
              <FilterSwitch
                checked={includeFinished}
                label={t('console.include_finished')}
                onChange={setIncludeFinished}
              />
            </>
          }
        />
      }>
      {rows.map(row => (
        <TableRow key={`${row.agent_uid}:${row.id}`}>
          <TableCell className="text-xs">{formatConsoleDate(row.due_at)}</TableCell>
          <AgentCell uid={row.agent_uid} />
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
            <StatusIndicator tone={eventTone(row.status)}>{eventStatusLabel(t, row.status)}</StatusIndicator>
          </TableCell>
          <TableCell className="w-12 text-right">
            {pending(row) ? (
              <ConfirmDeleteButton
                confirm={{
                  title: t('console.schedules.cancel_title'),
                  description: t('console.schedules.cancel_description'),
                  confirmLabel: t('console.schedules.cancel')
                }}
                icon={<RiCloseCircleLine />}
                pending={cancelCheckback.isPending}
                onConfirm={() =>
                  cancelCheckback.mutate({ path: { agent_uid: row.agent_uid, scheduled_event_id: row.id } })
                }
              />
            ) : (
              <span className="text-xs text-muted-foreground">—</span>
            )}
          </TableCell>
        </TableRow>
      ))}
    </ResourceListPage>
  )
}

function ScheduleTabs({ scope }: { scope: AgentScope }) {
  const { t } = useTranslation()
  const suffix = scope.agentUID ? `?agent=${encodeURIComponent(scope.agentUID)}` : ''
  return (
    <SubNav
      ariaLabel={t('console.schedules.title')}
      items={[
        { to: `/schedules${suffix}`, label: t('console.schedules.cron_tab'), end: true },
        { to: `/schedules/checkbacks${suffix}`, label: t('console.schedules.checkbacks_tab') }
      ]}
    />
  )
}

export function ScheduleCronEditorPage() {
  useSignals()
  const { t } = useTranslation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const model = useModel(ScheduleEditorModel)
  const [searchParams, setSearchParams] = useSearchParams()

  const routeAgentUID = searchParams.get('agent') ?? ''
  const cronID = searchParams.get('cron') ?? undefined
  const editing = Boolean(cronID)

  const agents = useQuery(ankoleWebAgentControllerIndexOptions())
  const agentList = agents.data?.agents ?? []
  // An existing schedule is pinned to its agent; a new one starts from the
  // resolved `?agent=` request.
  const agentUID = editing ? routeAgentUID : resolveAgentUID(agentList, routeAgentUID)

  const selectAgent = (uid: string) => {
    setSearchParams({ agent: uid }, { replace: true })
    model.resetAgentScope()
  }

  const bindings = useQuery({
    ...ankoleWebSignalBindingControllerIndexOptions({ query: { agent: agentUID } }),
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

  // Save errors render once in the page ErrorBlock; a toast on top of the
  // same message would say it twice.
  const saveCron = useMutation({
    ...ankoleWebScheduleControllerCreateCronMutation(),
    onSuccess: () => {
      toast.success(t('console.schedules.saved'))
      void queryClient.invalidateQueries()
      navigate(backTo)
    }
  })
  const updateCron = useMutation({
    ...ankoleWebScheduleControllerUpdateCronMutation(),
    onSuccess: () => {
      toast.success(t('console.schedules.saved'))
      void queryClient.invalidateQueries()
      navigate(backTo)
    }
  })

  const invalidate = () => void queryClient.invalidateQueries()
  const runCron = useMutation({
    ...ankoleWebScheduleControllerRunCronMutation(),
    onSuccess: () => {
      toast.success(t('console.schedules.ran'))
      invalidate()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
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
  const removeCron = useMutation({
    ...ankoleWebScheduleControllerRemoveCronMutation(),
    onSuccess: () => {
      toast.success(t('console.schedules.deleted'))
      invalidate()
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
      if (!cronID || !existingRow || !isMutableCronStatus(existingRow.status)) return
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
    if (!model.ownerSessionId.value.trim()) {
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

  const backTo = agentUID ? `/schedules?agent=${encodeURIComponent(agentUID)}` : '/schedules'
  const updateBody = editing ? model.toUpdateBody() : undefined
  const unchanged = Boolean(editing && updateBody && Object.keys(updateBody).length === 0)
  const existingRunnable = Boolean(existingRow && isMutableCronStatus(existingRow.status))
  const terminalReadOnly = Boolean(editing && existingRow && !existingRunnable)

  return (
    <ResourceEditorPage
      title={editing ? t('console.schedules.edit') : t('console.schedules.new')}
      backTo={backTo}
      description={
        terminalReadOnly && existingRow
          ? t('console.schedules.terminal_read_only', { status: scheduleStatusLabel(t, existingRow.status) })
          : undefined
      }
      error={
        model.validationError.value ??
        agents.error ??
        bindings.error ??
        existing.error ??
        saveCron.error ??
        updateCron.error
      }
      {...(terminalReadOnly
        ? { readOnly: true as const }
        : {
            onSubmit: submit,
            submitting: saveCron.isPending || updateCron.isPending,
            submitDisabled: unchanged,
            submitDisabledReason: t('common.save_disabled'),
            submitUnavailable: Boolean(editing && !existingRow)
          })}
      secondary={
        editing && existingRow ? (
          <div className="flex flex-wrap items-center gap-2">
            {existingRunnable ? (
              <Button
                size="sm"
                type="button"
                variant="outline"
                disabled={runCron.isPending}
                onClick={() =>
                  runCron.mutate({
                    headers: { 'Idempotency-Key': crypto.randomUUID() },
                    path: { agent_uid: agentUID, cron_schedule_id: existingRow.id }
                  })
                }>
                <RiPlayCircleLine data-icon="inline-start" />
                {t('console.schedules.run_now')}
              </Button>
            ) : null}
            {existingRunnable ? (
              <Button
                size="sm"
                type="button"
                variant="outline"
                disabled={pauseCron.isPending || resumeCron.isPending}
                onClick={() => {
                  const path = { agent_uid: agentUID, cron_schedule_id: existingRow.id }
                  if (existingRow.status === 'paused') resumeCron.mutate({ path })
                  else pauseCron.mutate({ path })
                }}>
                {existingRow.status === 'paused' ? (
                  <RiPlayCircleLine data-icon="inline-start" />
                ) : (
                  <RiPauseCircleLine data-icon="inline-start" />
                )}
                {existingRow.status === 'paused' ? t('console.schedules.resume') : t('console.schedules.pause')}
              </Button>
            ) : null}
            <ConfirmDeleteButton
              confirm={{
                title: t('console.schedules.delete_title'),
                description: t('console.schedules.delete_description', {
                  name: existingRow.name || existingRow.binding_name
                }),
                confirmLabel: t('common.delete')
              }}
              label={t('common.delete')}
              pending={removeCron.isPending}
              size="sm"
              onConfirm={() => removeCron.mutate({ path: { agent_uid: agentUID, cron_schedule_id: existingRow.id } })}
            />
          </div>
        ) : undefined
      }
      supplementary={
        editing ? (
          <div className="flex flex-col gap-3">
            <h3 className="text-sm font-medium">{t('console.schedules.run_history')}</h3>
            <ErrorBlock error={runs.error} />
            {runs.error ? null : runRows.length === 0 ? (
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
                          <StatusIndicator tone={eventTone(row.status)}>
                            {eventStatusLabel(t, row.status)}
                          </StatusIndicator>
                        </TableCell>
                        <TableCell className="text-xs">{formatConsoleDate(row.fired_at)}</TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              </div>
            )}
          </div>
        ) : null
      }>
      <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
        <LabeledField label={t('console.agents.agent')} required={!editing}>
          {editing ? (
            <ReadOnlyValue mono>{agentUID || '—'}</ReadOnlyValue>
          ) : (
            <Select value={agentUID || null} onValueChange={value => selectAgent(String(value))}>
              <SelectTrigger className="w-full">
                <SelectValue placeholder={t('console.select_agent')} />
              </SelectTrigger>
              <SelectContent emptyLabel={agents.isLoading ? t('common.loading') : t('common.select_no_agents')}>
                {agentList.map(agent => (
                  <SelectItem key={agent.uid} value={agent.uid}>
                    {agent.uid}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
        </LabeledField>
        {editing ? (
          <LabeledField label={t('console.schedules.owner_session')}>
            <ReadOnlyValue mono>{model.ownerSessionId.value || '—'}</ReadOnlyValue>
          </LabeledField>
        ) : (
          <LabeledField
            label={t('console.schedules.owner_session')}
            required
            description={t('console.schedules.session_hint')}>
            <CreatableCombobox
              ariaLabel={t('console.schedules.owner_session')}
              clearLabel={t('common.clear')}
              value={model.ownerSessionId.value}
              options={sessionList.map(session => ({
                value: session.session_id,
                label: session.title ? `${session.title} — ${session.session_id}` : session.session_id
              }))}
              placeholder={t('console.schedules.session_placeholder')}
              emptyLabel={sessions.isLoading ? t('common.loading') : t('console.schedules.session_empty')}
              createLabel={value => t('console.schedules.session_use', { session: value })}
              triggerLabel={t('common.open')}
              onValueChange={value => (model.ownerSessionId.value = value)}
            />
          </LabeledField>
        )}
      </div>

      {editing && existingRow ? (
        <LabeledField
          label={t('console.schedules.execution_session')}
          description={t('console.schedules.execution_session_hint')}>
          <ReadOnlyValue mono>{existingRow.execution_session_id}</ReadOnlyValue>
        </LabeledField>
      ) : null}

      <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
        <LabeledField label={t('console.schedules.binding')} required>
          {editing ? (
            <ReadOnlyValue mono>{model.bindingName.value || '—'}</ReadOnlyValue>
          ) : (
            <Select value={model.bindingName.value} onValueChange={value => model.setBindingName(String(value))}>
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
          )}
        </LabeledField>
        <LabeledField label={t('console.schedules.name')} description={t('console.schedules.name_hint')}>
          <Input value={model.name.value} onChange={event => (model.name.value = event.target.value)} />
        </LabeledField>
      </div>

      <LabeledField
        label={t('console.schedules.task')}
        required={!model.hasAutomationJob.value}
        description={t('console.schedules.task_hint')}>
        <Textarea rows={4} value={model.task.value} onChange={event => (model.task.value = event.target.value)} />
      </LabeledField>

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
          <LabeledField
            label={t('console.schedules.anchor_at')}
            required
            description={t('console.schedules.anchor_hint')}>
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

      <div className="flex flex-col gap-3">
        <div className="flex items-start justify-between gap-3">
          <div>
            <h3 className="text-sm font-medium">{t('console.schedules.delivery_targets')}</h3>
            <p className="text-xs text-muted-foreground">{t('console.schedules.delivery_targets_hint')}</p>
          </div>
          <Button type="button" size="sm" variant="outline" onClick={() => model.addDeliveryTarget()}>
            {t('console.schedules.add_delivery_target')}
          </Button>
        </div>

        {model.deliveryTargets.value.map((target, index) => (
          <div key={index} className="flex flex-col gap-3 border border-border p-3">
            <div className="flex items-center justify-between gap-3">
              <span className="text-xs font-medium text-muted-foreground">
                {t('console.schedules.delivery_target', { number: index + 1 })}
              </span>
              {index > 0 ? (
                <Button type="button" size="xs" variant="ghost" onClick={() => model.removeDeliveryTarget(index)}>
                  {t('common.delete')}
                </Button>
              ) : null}
            </div>

            <div className="grid grid-cols-1 gap-3 md:grid-cols-3">
              <LabeledField label={t('console.schedules.binding')} required>
                {index === 0 ? (
                  <ReadOnlyValue mono>{model.bindingName.value || '—'}</ReadOnlyValue>
                ) : (
                  <Select
                    value={target.bindingName}
                    onValueChange={value => model.updateDeliveryTarget(index, { bindingName: String(value) })}>
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
                )}
              </LabeledField>
              <LabeledField label={t('console.schedules.delivery_channel')} required>
                <Input
                  value={target.channelId}
                  onChange={event => model.updateDeliveryTarget(index, { channelId: event.target.value })}
                />
              </LabeledField>
              <LabeledField label={t('console.schedules.delivery_thread')}>
                <Input
                  value={target.threadId}
                  onChange={event => model.updateDeliveryTarget(index, { threadId: event.target.value })}
                />
              </LabeledField>
            </div>
          </div>
        ))}
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
              <SelectItem value="active">{t('console.schedules.status_active')}</SelectItem>
              <SelectItem value="paused">{t('console.schedules.status_paused')}</SelectItem>
            </SelectContent>
          </Select>
        </LabeledField>
      ) : null}
    </ResourceEditorPage>
  )
}

// helpers

/** Localized status labels; an unknown token renders as itself instead of a raw i18n key. */
function scheduleStatusLabel(t: TFunction, status: string): string {
  return t(`console.schedules.status_${status}`, { defaultValue: status })
}

function eventStatusLabel(t: TFunction, status: string): string {
  return t(`console.schedules.event_status_${status}`, { defaultValue: status })
}

function describeSchedule(t: TFunction, schedule: Record<string, unknown> | null | undefined): string {
  if (!schedule || typeof schedule !== 'object') return '—'
  const kind = String((schedule as { kind?: unknown }).kind ?? '')
  if (kind === 'cron') return String((schedule as { expression?: unknown }).expression ?? '—')
  if (kind === 'every') {
    const ms = Number((schedule as { every_ms?: unknown }).every_ms)
    const interval =
      !Number.isFinite(ms) || ms <= 0
        ? '?'
        : ms >= 86_400_000 && ms % 86_400_000 === 0
          ? `${ms / 86_400_000}d`
          : ms >= 3_600_000 && ms % 3_600_000 === 0
            ? `${ms / 3_600_000}h`
            : ms >= 60_000 && ms % 60_000 === 0
              ? `${ms / 60_000}m`
              : `${ms}ms`
    return t('console.schedules.every_interval', { interval })
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
  const payload = row.payload ?? {}
  return {
    ownerSessionId: row.owner_session_id,
    bindingName: row.binding_name,
    name: row.name ?? '',
    status: isMutableCronStatus(row.status) ? row.status : '',
    scheduleKind: kind,
    cronExpression: String(schedule.expression ?? ''),
    everyMs: String(schedule.every_ms ?? ''),
    anchorAt: String(schedule.anchor_at ?? ''),
    timezone: row.timezone ?? '',
    occurrences: scheduleOccurrenceBound(schedule),
    deliveryTargets: deliveryTargetDrafts(row.delivery, row.binding_name),
    task: typeof payload.task === 'string' ? payload.task : '',
    payload: safeStringify(payload),
    hasAutomationJob: row.automation_job_id != null,
    idempotencyKey: row.idempotency_key ?? ''
  }
}

function safeStringify(value: unknown): string {
  try {
    return JSON.stringify(value, null, 2)
  } catch {
    return '{}'
  }
}

function emptyDraft(): ScheduleEditorDraft {
  return {
    ownerSessionId: '',
    bindingName: '',
    name: '',
    status: 'active',
    scheduleKind: 'cron',
    cronExpression: '',
    everyMs: '',
    anchorAt: '',
    timezone: '',
    deliveryTargets: [{ bindingName: '', channelId: '', threadId: '' }],
    task: '',
    payload: '{}',
    hasAutomationJob: false,
    idempotencyKey: ''
  }
}
